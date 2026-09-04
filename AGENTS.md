# Agent Instructions

* Make only the changes necessary for the requested task.
* Commit each completed logical change separately.
* Update package versions according to OpenWrt versioning rules.
* Do not build the project.
* Do not run, add, or modify tests.
* Remove obsolete or dead code made unnecessary by the changes.
* Prefer native LuCI components and APIs over custom UI implementations.
* Follow OpenWrt, LuCI, ucode, POSIX shell, and Rust best practices.
* Keep Rust code compatible with OpenWrt, musl, and cross-compilation.
* Avoid unnecessary Rust dependencies, allocations, clones, threads, and background work.
* Avoid unrelated refactoring or formatting changes.
* Preserve existing behavior, configuration formats, and UI unless the request requires otherwise.
* Use LF line endings for all files.
