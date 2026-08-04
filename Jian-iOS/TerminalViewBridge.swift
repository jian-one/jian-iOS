import SwiftTerm
import SwiftUI
import UIKit

struct TerminalViewBridge: UIViewRepresentable {
    let socket: TerminalSocket

    func makeUIView(context: Context) -> UltimationTerminalView {
        let view = UltimationTerminalView(frame: .zero)
        view.configure(socket: socket)
        return view
    }

    func updateUIView(_ uiView: UltimationTerminalView, context: Context) {
        uiView.configure(socket: socket)
    }
}

/// Stores the complete raw stream outside SwiftTerm's working buffer. The
/// index is deliberately only line offsets, so long-lived terminal sessions do
/// not retain their complete transcript in RAM.
private final class TerminalOutputStore {
    private let url: URL
    private let writer: FileHandle?
    private var memoryFallback = Data()
    private var byteCount: UInt64 = 0
    private var lineStarts: [UInt64] = [0]

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jian-terminal-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        writer = try? FileHandle(forWritingTo: url)
    }

    deinit {
        try? writer?.close()
        try? FileManager.default.removeItem(at: url)
    }

    var totalLines: Int {
        byteCount == 0 ? 0 : lineStarts.count
    }

    func append(_ text: String) {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }

        if let writer {
            try? writer.write(contentsOf: data)
        } else {
            memoryFallback.append(data)
        }

        for (index, byte) in data.enumerated() where byte == 0x0A {
            lineStarts.append(byteCount + UInt64(index) + 1)
        }
        byteCount += UInt64(data.count)
    }

    func data(for range: Range<Int>) -> Data {
        let lower = min(max(0, range.lowerBound), totalLines)
        let upper = min(max(lower, range.upperBound), totalLines)
        guard lower < upper else { return Data() }

        let start = lineStarts[lower]
        let end = upper < lineStarts.count ? lineStarts[upper] : byteCount
        let count = Int(end - start)
        guard count > 0 else { return Data() }

        if let reader = try? FileHandle(forReadingFrom: url) {
            defer { try? reader.close() }
            try? reader.seek(toOffset: start)
            return (try? reader.read(upToCount: count)) ?? Data()
        }

        let startIndex = Int(start)
        return memoryFallback.subdata(in: startIndex..<(startIndex + count))
    }
}

final class UltimationTerminalView: TerminalView, TerminalViewDelegate, UIGestureRecognizerDelegate {
    private static let maximumDisplayLines = 5_000
    private static let historyPageLines = 500
    private static let maximumFeedChunkUTF8Bytes = 32 * 1024

    private weak var socket: TerminalSocket?
    private var outputStore = TerminalOutputStore()
    private var displayRange = 0..<0
    private var hasReceivedInitialReplay = false
    private var isRebuildingWindow = false
    private var needsLatestRefresh = false
    private var viewportFollowState = TerminalViewportFollowState()
    private var isApplyingProgrammaticScroll = false
    private var historyOffsetY: CGFloat = 0
    private var refreshLink: CADisplayLink?
    private var tapToDismissKeyboardRecognizer: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        terminalDelegate = self
        backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.04, alpha: 1)
        keyboardAppearance = .dark
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        alwaysBounceVertical = true
        bounces = true
        isScrollEnabled = true
        decelerationRate = .normal
        showsVerticalScrollIndicator = true
        keyboardDismissMode = .onDrag
        delaysContentTouches = false
        canCancelContentTouches = true
        allowMouseReporting = false
        prepareTerminalForWindow()
        installKeyboardDismissGestures()
        panGestureRecognizer.addTarget(self, action: #selector(nativeScrollPanChanged(_:)))
    }

    deinit {
        refreshLink?.invalidate()
        if let tapToDismissKeyboardRecognizer {
            removeGestureRecognizer(tapToDismissKeyboardRecognizer)
        }
        panGestureRecognizer.removeTarget(self, action: #selector(nativeScrollPanChanged(_:)))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)

        // SwiftTerm lazily adds pan recognizers for text selection and terminal
        // mouse reporting. Once one of them wins, it consumes every drag and
        // UIScrollView never gets a chance to scroll. This screen deliberately
        // reserves drags for native history scrolling; taps still focus input.
        if let pan = gestureRecognizer as? UIPanGestureRecognizer,
           pan !== panGestureRecognizer {
            pan.isEnabled = false
        }
    }

    func configure(socket: TerminalSocket) {
        guard self.socket !== socket else { return }
        self.socket = socket
        resetTranscript()
        socket.observeTerminal(
            output: { [weak self] text in self?.receiveOutput(text) },
            initialReplayComplete: { [weak self] in self?.finishInitialReplay() }
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopRealtimeRefresh()
        } else {
            startRealtimeRefresh()
        }
    }

    override func layoutSubviews() {
        UIView.performWithoutAnimation {
            super.layoutSubviews()
        }
    }

    private func resetTranscript() {
        outputStore = TerminalOutputStore()
        displayRange = 0..<0
        hasReceivedInitialReplay = false
        isRebuildingWindow = false
        needsLatestRefresh = false
        viewportFollowState.reset()
        isHidden = true
        prepareTerminalForWindow()
    }

    private func receiveOutput(_ text: String) {
        outputStore.append(text)
        guard hasReceivedInitialReplay, shouldFollowOutput else { return }
        if isRebuildingWindow {
            needsLatestRefresh = true
            return
        }

        UIView.performWithoutAnimation {
            feedInChunks(text)
        }
        displayRange = latestWindowRange()
        settleViewport()
        setNeedsDisplay(bounds)
    }

    private func finishInitialReplay() {
        guard !hasReceivedInitialReplay else { return }
        hasReceivedInitialReplay = true
        shouldFollowOutput = true
        rebuildWindow(latestWindowRange(), anchorLine: nil)
        DispatchQueue.main.async { [weak self] in
            self?.isHidden = false
        }
    }

    private func latestWindowRange() -> Range<Int> {
        let end = outputStore.totalLines
        return max(0, end - Self.maximumDisplayLines)..<end
    }

    private func rebuildWindow(_ range: Range<Int>, anchorLine: Int?) {
        guard !isRebuildingWindow else { return }
        isRebuildingWindow = true
        let clamped = max(0, range.lowerBound)..<min(outputStore.totalLines, range.upperBound)
        let data = outputStore.data(for: clamped)

        UIView.performWithoutAnimation {
            prepareTerminalForWindow()
            if !data.isEmpty {
                feedInChunks(String(decoding: data, as: UTF8.self))
            }
            displayRange = clamped
            layoutIfNeeded()

            if let anchorLine {
                let lineOffset = max(0, anchorLine - clamped.lowerBound)
                applyHistoryOffset(CGFloat(lineOffset) * font.lineHeight)
            } else {
                jumpToLatestContent()
            }
            setNeedsDisplay(bounds)
        }
        isRebuildingWindow = false
        if needsLatestRefresh, shouldFollowOutput {
            needsLatestRefresh = false
            rebuildWindow(latestWindowRange(), anchorLine: nil)
        }
    }

    private func prepareTerminalForWindow() {
        let emulator = getTerminal()
        // Give SwiftTerm a full native scrollback window. The viewport rows are
        // additional, so a short device height never disables scrolling.
        emulator.changeScrollback(Self.maximumDisplayLines)
        emulator.setup(isReset: true)
    }

    private var isNearTop: Bool {
        contentOffset.y <= minContentOffsetY + 1
    }

    private var isNearBottom: Bool {
        guard contentSize.height > 0, bounds.height > 0 else { return true }
        let visibleBottomY = contentOffset.y + bounds.height - adjustedContentInset.bottom
        return contentSize.height - visibleBottomY <= 24
    }

    private var minContentOffsetY: CGFloat {
        -adjustedContentInset.top
    }

    private var maxContentOffsetY: CGFloat {
        max(minContentOffsetY, contentSize.height - bounds.height + adjustedContentInset.bottom)
    }

    private var shouldFollowOutput: Bool {
        get { viewportFollowState.shouldFollowOutput }
        set { viewportFollowState.setFollowing(newValue) }
    }

    private func feedInChunks(_ text: String) {
        for chunk in text.chunks(maxUTF8Bytes: Self.maximumFeedChunkUTF8Bytes) {
            feed(text: chunk)
        }
    }

    private func jumpToLatestContent() {
        guard contentSize.height > 0, bounds.height > 0 else { return }
        applyHistoryOffset(maxContentOffsetY)
    }

    private func applyHistoryOffset(_ offsetY: CGFloat) {
        let clampedY = min(maxContentOffsetY, max(minContentOffsetY, offsetY))
        historyOffsetY = clampedY
        isApplyingProgrammaticScroll = true
        setContentOffset(CGPoint(x: contentOffset.x, y: clampedY), animated: false)
        isApplyingProgrammaticScroll = false
    }

    private func settleViewport() {
        jumpToLatestContent()
    }

    @objc private func nativeScrollPanChanged(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began else { return }
        beginUserScrollIfNeeded()
    }

    private func beginUserScrollIfNeeded() {
        guard hasReceivedInitialReplay,
              !isRebuildingWindow,
              !isApplyingProgrammaticScroll,
              !viewportFollowState.isUserScrolling
        else { return }
        viewportFollowState.userScrollBegan()
        historyOffsetY = min(maxContentOffsetY, max(minContentOffsetY, contentOffset.y))
    }

    private func finishUserScroll() {
        guard viewportFollowState.isUserScrolling else { return }
        let endedNearBottom = isNearBottom
        let shouldResumeFollowing = viewportFollowState.userScrollEnded(isNearBottom: endedNearBottom)

        if shouldResumeFollowing {
            let latestRange = latestWindowRange()
            if displayRange != latestRange {
                rebuildWindow(latestRange, anchorLine: nil)
            } else {
                jumpToLatestContent()
            }
            return
        }

        historyOffsetY = min(maxContentOffsetY, max(minContentOffsetY, contentOffset.y))
        guard !getTerminal().isCurrentBufferAlternate else { return }
        if isNearTop {
            loadOlderHistory()
        } else if isNearBottom, displayRange.upperBound < outputStore.totalLines {
            loadNewerHistory()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        beginUserScrollIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasReceivedInitialReplay,
              !isRebuildingWindow,
              !isApplyingProgrammaticScroll,
              viewportFollowState.isUserScrolling
        else { return }
        viewportFollowState.userScrolled(isNearBottom: isNearBottom)
        historyOffsetY = min(maxContentOffsetY, max(minContentOffsetY, contentOffset.y))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            finishUserScroll()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishUserScroll()
    }

    private func loadOlderHistory() {
        guard !getTerminal().isCurrentBufferAlternate,
              displayRange.lowerBound > 0,
              !isRebuildingWindow
        else { return }
        let previousStart = displayRange.lowerBound
        let start = max(0, previousStart - Self.historyPageLines)
        let end = min(outputStore.totalLines, start + Self.maximumDisplayLines)
        shouldFollowOutput = false
        rebuildWindow(start..<end, anchorLine: previousStart)
    }

    private func loadNewerHistory() {
        let total = outputStore.totalLines
        guard !getTerminal().isCurrentBufferAlternate, !isRebuildingWindow else { return }
        guard displayRange.upperBound < total else {
            shouldFollowOutput = true
            jumpToLatestContent()
            return
        }
        let previousEnd = displayRange.upperBound
        let end = min(total, previousEnd + Self.historyPageLines)
        let start = max(0, end - Self.maximumDisplayLines)
        shouldFollowOutput = end == total
        rebuildWindow(start..<end, anchorLine: previousEnd)
    }

    private func startRealtimeRefresh() {
        guard refreshLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refreshTerminalFrame))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        } else {
            link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        refreshLink = link
    }

    private func stopRealtimeRefresh() {
        refreshLink?.invalidate()
        refreshLink = nil
    }

    @objc private func refreshTerminalFrame() {
        guard window != nil else {
            stopRealtimeRefresh()
            return
        }
        setNeedsDisplay(bounds)
    }

    private func installKeyboardDismissGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapTerminalWhileEditing))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        addGestureRecognizer(tap)
        tapToDismissKeyboardRecognizer = tap
        panGestureRecognizer.isEnabled = true
    }

    @objc private func didTapTerminalWhileEditing() {
        guard isFirstResponder else { return }
        _ = resignFirstResponder()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === tapToDismissKeyboardRecognizer {
            return isFirstResponder
        }
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === tapToDismissKeyboardRecognizer ||
            otherGestureRecognizer === tapToDismissKeyboardRecognizer
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        socket?.sendResize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !isRebuildingWindow else { return }
        socket?.sendInput(String(decoding: data, as: UTF8.self))
    }

    func scrolled(source: TerminalView, position: Double) {}

    override func mouseModeChanged(source: Terminal) {
        // Codex and Hermes enable mouse reporting. Keep native UIScrollView
        // scrolling active so drag bounce and deceleration remain available.
        panGestureRecognizer.isEnabled = true
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = text
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private extension String {
    func chunks(maxUTF8Bytes: Int) -> [String] {
        guard maxUTF8Bytes > 0, !isEmpty else { return [] }

        var chunks: [String] = []
        var chunkStart = startIndex
        var chunkBytes = 0
        var index = startIndex

        while index < endIndex {
            let nextIndex = self.index(after: index)
            let characterBytes = self[index..<nextIndex].utf8.count

            if chunkBytes > 0, chunkBytes + characterBytes > maxUTF8Bytes {
                chunks.append(String(self[chunkStart..<index]))
                chunkStart = index
                chunkBytes = 0
            }

            chunkBytes += characterBytes
            index = nextIndex
        }

        if chunkStart < endIndex {
            chunks.append(String(self[chunkStart..<endIndex]))
        }

        return chunks
    }
}
