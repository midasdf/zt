# macOS manual QA

Run this checklist on a Mac with a desktop session after `zig build test`.
Run `zig build test -Dmacos_gui_tests=true` to also exercise real Cocoa window
creation, drawing, input callbacks, candidate geometry, large pastes, and closing.
These checks do not simulate physical keyboard input or IME candidate selection.

Validated locally on Apple Silicon: release build, PTY/unit tests, Cocoa
integration tests, app signature and Finder launch. Intel cross-build also passes;
Intel runtime checks run in CI. Full manual checks below remain to be completed.

- Launch `./zig-out/bin/zt` and `open zig-out/zt.app`; confirm a shell prompt appears.
- Type ASCII, shifted punctuation, and Japanese keyboard-layout punctuation.
- Check Enter, Tab, Backspace, arrows, Ctrl+C, Ctrl+D, and Option+letter.
- Switch to Japanese IME, compose text, move the candidate selection with arrows,
  commit with Enter, and cancel with Escape. Confirm text appears once, composition
  is underlined, and the candidate window follows the cursor.
- Select text with a mouse drag; copy with Cmd+C and paste with Cmd+V.
- Run `cat` and paste multiline text, then Ctrl+D. Check bracketed paste in a shell
  or editor that enables it.
- Scroll shell history; check wheel behavior in `less` and mouse-enabled `vim`.
- Resize the window; run `stty size` and confirm rows and columns track the window.
- Print colors and Japanese text; confirm the image is upright and readable.
- Move between Retina and non-Retina displays and check redraw.
- Change the title with `printf '\033]2;macOS test\007'`.
- Switch focus away and back; check input and cursor blinking still work.
- Run sustained output and confirm input/window controls remain responsive.
- Close with Cmd+W, Cmd+Q, the titlebar close button, and shell `exit`.
- Repeat launch/resize/close on an Intel Mac to exercise Objective-C struct returns.
