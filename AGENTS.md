# Jian-iOS project constraints

- This project is the iOS client for Jian.
- The `jian/` directory contains the Jian service implementation and is
  read-only for iOS work. Do not modify, format, regenerate, build-generated
  files into, or otherwise write to the Jian server source or its artifacts.
- When the server contract changes, inspect `jian/` as needed and update only
  the iOS client (`Jian-iOS/`, project files, and client tests/scripts).
- Keep client API paths, HTTP methods, request bodies, response models, and
  WebSocket paths aligned with the current server contract.
