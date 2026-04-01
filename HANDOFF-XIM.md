# zt XIM (日本語入力) 実装 引き継ぎプロンプト

以下をそのまま次セッションの最初のプロンプトとして使う。

---

ztターミナルエミュレータに日本語入力（XIM）サポートを追加してほしい。最速で動く実装をお願い。

## 背景

- zt: ~/zt/ にあるZig製ターミナル。X11バックエンドはXCB+SHMで動作
- 現状: キーイベントをXCBから直接受け取り、input.zigのUS QWERTYマップで変換。IMEが介入する余地がない
- ゴール: fcitx5-mozc等のIMEで日本語入力できるようにする

## 実装方針: xcb-imdkit（純XCBのXIMクライアント）

Xlib併用ではなく xcb-imdkit を使う。理由:
- ztは純XCB設計。Xlibを混ぜる必要がない
- `xcb_xim_filter_event`にXCBイベントを直接渡せる（変換不要）
- fcitx5の開発者(wengxt)が作ったライブラリで、fcitx5との互換性最高
- 依存サイズ ~50KB（Xlibは~1.5MB）
- Archでは `xcb-imdkit` パッケージとして既にインストール済み

### xcb-imdkit クライアントAPI概要

ヘッダ: `/usr/include/xcb-imdkit/imclient.h`
リンク: `-lxcb-imdkit -lxcb-util -lxcb`

**コア関数:**
```c
// 作成・接続
xcb_xim_t *xcb_xim_create(xcb_connection_t *conn, int screen_id, const char *imname);
bool xcb_xim_open(xcb_xim_t *im, xcb_xim_open_callback callback, bool auto_connect, void *user_data);
void xcb_xim_set_im_callback(xcb_xim_t *im, const xcb_xim_im_callback *callbacks, void *user_data);
void xcb_xim_set_use_utf8_string(xcb_xim_t *im, bool enable);

// IC作成
bool xcb_xim_create_ic(xcb_xim_t *im, xcb_xim_create_ic_callback callback, void *user_data, ...);
bool xcb_xim_set_ic_focus(xcb_xim_t *im, xcb_xic_t ic);

// イベント処理（最重要）
bool xcb_xim_filter_event(xcb_xim_t *im, xcb_generic_event_t *event);
bool xcb_xim_forward_event(xcb_xim_t *im, xcb_xic_t ic, xcb_key_press_event_t *event);

// クリーンアップ
void xcb_xim_close(xcb_xim_t *im);
void xcb_xim_destroy(xcb_xim_t *im);
```

**コールバック構造体 (xcb_xim_im_callback):**
```c
typedef struct _xcb_xim_im_callback {
    xcb_xim_commit_string_callback commit_string;   // 確定テキスト受信（最重要）
    xcb_xim_forward_event_callback forward_event;    // IME未処理キーの返送
    xcb_xim_set_event_mask_callback set_event_mask;  // イベントマスク設定
    // preedit系: preedit_start, preedit_draw, preedit_caret, preedit_done
    // status系: status_start, status_draw_text, status_draw_bitmap, status_done
    // その他: geometry, sync, disconnected
} xcb_xim_im_callback;
```

**commit_stringコールバック:**
```c
typedef void (*xcb_xim_commit_string_callback)(
    xcb_xim_t *im, xcb_xic_t ic,
    uint32_t flag, char *str, uint32_t length,
    uint32_t *keysym, size_t nKeySym,
    void *user_data
);
// str にUTF-8の確定テキストが来る → PTYにwrite
```

### 変更ファイルと内容

**build.zig**: リンク追加
```zig
exe.linkSystemLibrary("xcb-imdkit");
exe.linkSystemLibrary("xcb-util");
```

**src/backend/x11.zig**:
1. `@cInclude("xcb-imdkit/imclient.h")` 追加
2. X11Backend structに追加フィールド:
   - `xim: ?*xcb_xim_t`
   - `xic: xcb_xic_t`
   - `committed_text: ?[]const u8` (コールバックから受け取ったテキスト)
   - `committed_len: usize`
3. `init()`で:
   - `xcb_xim_create(connection, screen_num, null)` — XMODIFIERSから自動検出
   - `xcb_xim_set_use_utf8_string(xim, true)` — UTF-8有効化
   - `xcb_xim_set_im_callback(xim, &callbacks, self_ptr)` — コールバック登録
   - `xcb_xim_open(xim, open_callback, true, self_ptr)` — auto_connect=true
   - open_callbackの中で `xcb_xim_create_ic(...)` を呼んでIC作成
4. `pollEvents()`の変更:
   - 全イベントを先に `xcb_xim_filter_event(xim, event)` に通す
   - trueが返ったらIMEが処理中 → スキップ
   - falseなら従来のXCB_KEY_PRESS処理へ
   - commit_stringコールバックで受け取ったテキストをEvent.textとして返す
5. Event unionに `.text: []const u8` variant追加
6. `deinit()`で `xcb_xim_close`, `xcb_xim_destroy`

**src/main.zig**: イベントハンドラに `.text` 分岐追加
```zig
.text => |text| {
    // IMEからの確定テキスト → PTYに直接write
    ptyBufferedWrite(&pty, text, &write_buf, &write_pending, epoll_fd);
},
```

### コールバック実装のポイント

xcb-imdkitはコールバックベースでCの関数ポインタを要求する。Zigでは:

```zig
fn commitStringCallback(
    im: ?*c.xcb_xim_t,
    ic: c.xcb_xic_t,
    flag: u32,
    str: [*c]u8,
    length: u32,
    keysym: [*c]u32,
    n_keysym: usize,
    user_data: ?*anyopaque,
) callconv(.C) void {
    const self: *X11Backend = @ptrCast(@alignCast(user_data));
    // str[0..length] が確定テキスト（UTF-8）
    self.committed_text_buf[0..length] = str[0..length];
    self.committed_len = length;
}
```

`user_data`にX11Backendのポインタを渡して、コールバック内でstructにテキストを書き込む。`pollEvents()`でそれを読み取ってEventとして返す。

### 非同期初期化の注意

`xcb_xim_open`は非同期。open_callbackが呼ばれるまでXIMは使えない。
`xcb_xim_create_ic`も非同期。create_ic_callbackでxicが返る。

→ xim/xicがnullの間は従来のキー処理にフォールバック。IMEなし環境でも壊れない。

### テスト方法

```sh
# ビルド
zig build -Dbackend=x11 -Doptimize=ReleaseSmall

# fcitx5が動いてる環境で
XMODIFIERS=@im=fcitx zt

# 日本語入力テスト: 半角/全角キーでIME切替、「nihongo」→変換→確定
```

### fbdevバックエンドへの影響

なし。xcb-imdkitはX11専用で、fbdevビルドにはリンクされない。

### pre-edit（変換中テキスト）表示

スコープ外。`XIMPreeditNothing`スタイルでIC作成すれば、IME側が変換候補ウィンドウを出す（fcitx5のデフォルト動作）。
将来的にインライン変換したければ `preedit_draw` コールバックで対応可能だが、まずはIME任せが最速。
