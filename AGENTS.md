# Agent Instructions

* Make only the changes necessary for the requested task.
* Commit each completed logical change separately.
* Version shipped changes explicitly:
  * Bump `WLOC_VERSION` using semantic versioning when application or source behavior changes: patch for fixes and refactors, minor for backward-compatible features, and major for breaking configuration, API, or behavior changes.
  * Bump `WLOC_RELEASE` only for OpenWrt packaging-only changes that do not change the application/source version.
  * Reset `WLOC_RELEASE` to `1` whenever `WLOC_VERSION` changes.
  * Do not bump package versions for documentation, `AGENTS.md`, CI, or other repository-only changes that do not alter the built package or runtime behavior.
* Do not build the project.
* Do not run, add, or modify tests.
* Remove obsolete or dead code made unnecessary by the changes.
* Never add backward compatibility, migration, or fallback logic for obsolete configuration formats or options; support only the current configuration model.
* Prefer native LuCI components and APIs over custom UI implementations.
* Follow OpenWrt, LuCI, ucode, POSIX shell, and Rust best practices.
* Keep Rust code compatible with OpenWrt, musl, and cross-compilation.
* Avoid unnecessary Rust dependencies, allocations, clones, threads, and background work.
* Avoid unrelated refactoring or formatting changes.
* Preserve existing behavior, configuration formats, and UI unless the request requires otherwise.
* Use LF line endings for all files.
