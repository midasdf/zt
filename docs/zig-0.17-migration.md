# Zig 0.17 migration

Source builds now require **Zig 0.17.0**. Older release notes describe the
compiler required by those releases and have intentionally been left unchanged.

## Changes

- Replace removed array repetition (`**`) with `@splat`, including nested arrays
  and sentinel-terminated environment arrays. Add explicit array types where the
  old expression inferred the length.
- Replace `Allocator.dupeZ` with `Allocator.dupeSentinel(..., 0)` and
  `std.fmt.bufPrintZ` with `std.fmt.bufPrintSentinel(..., 0)` to preserve NUL
  termination for C APIs, PTY environment variables, and executable paths.
- Use the new optimization enum tags (`.debug`, `.fast`). Existing command-line
  spellings such as `-Doptimize=ReleaseFast` still work in Zig 0.17.
- Apply Zig 0.17 formatting, which migrates `@intFromEnum` to `@backingInt`.
- Update the package's minimum compiler version, CI/release compiler downloads,
  Docker compiler pin, local Xvfb compiler lookup, and README installation steps.
- Extend Linux CI to build framebuffer and test both X11 and Wayland, and check
  that both font-conversion tools compile.

No terminal behavior or configuration defaults were intentionally changed.

## Local verification

Verified with Zig `0.17.0` on Apple Silicon macOS:

| Check | Result |
| --- | --- |
| `zig fmt --check .` | Passed |
| Native debug and fast builds | Passed |
| `zig build test` | 176 passed, 2 skipped |
| `zig build test -Dmacos_gui_tests=true` | 177 passed, 1 skipped |
| GUI tests with `-Dscrollback_lines=0` | 158 passed, 20 skipped (configuration-dependent coverage) |
| Intel macOS fast cross-build | Passed |
| AArch64 and x86_64 Linux framebuffer debug/small cross-builds | Passed |
| AArch64 Linux X11 and Wayland debug/fast cross-builds | Passed using the local sysroot |
| Both font tools, standalone compilation | Passed |
| Custom BDF build | Passed with a one-glyph fixture |
| Custom TTF build | Passed with macOS `SFNSMono.ttf` (1,318 glyphs) |
| Native app running a short `-e /bin/sh -c ...` command | Exited successfully |
| App packaging, `plutil -lint`, strict signature verification | Passed |

The Linux sysroot contains AArch64 shared libraries. Its Wayland dependencies
require a sufficiently recent glibc, so the final X11/Wayland checks used
`-Dtarget=aarch64-linux-gnu.2.38 -Dsysroot=/path/to/sysroot/usr`.

Linux runtime tests, Docker builds, and GitHub Actions have not been run locally:
the host is macOS and the Docker daemon is unavailable. Linux runtime coverage is
configured in CI. Physical IME interaction and multi-display QA remain manual
checks; see [macOS QA](macos-qa.md).
