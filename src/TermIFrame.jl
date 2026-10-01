"""
    TermIFrame

An iframe for the terminal: another program, running in a multiplexer session,
drawn inside a box your own TUI lays out.

The name is the design. An HTML iframe embeds a document the host page does not
understand, sizes it, and forwards events into it; the document scrolls and
draws inside its own rectangle and knows nothing about what is around it. This
is that, for a terminal - and a tmux session is what makes it possible, because
a session holds a program that outlives the view of it and whose screen can be
read back *as text*, without the reader having to understand a single escape
sequence.

What that buys, over handing the whole terminal to a child and getting nothing
back: `vi`, a pager, a build and an agent are the same amount of work, a program
this does not know about is no work at all, and the child keeps running when you
look away.

    using TermIFrame

    mux_start("demo", pwd(), "htop")
    f = iframe("demo", "htop")
    c = f.client
    @async (while mux_wait(c); redraw(); end; redraw())   # output, and the end

    box = iframe_box(w, h)                 # the child's size inside your box
    iframe_sync!(f, box)                   # size it, read its screen
    rows_to_print = iframe_rows(f, w, h)   # `h` rows of exactly `w` columns
    r = iframe_input!(f, bytes, iframe_origin(x, y), box)
    # `r` is `:ok`, `:gone`, or the key typed after `^]` - the host's to act
    # on, before it calls again with no bytes to send on the rest

The host owns the layout: nothing here asks `displaysize`, because an iframe
drawn beside something else is the case that matters. What it owns instead is
the box, the child's coordinates, the scrollback the child does not provide, and
one prefix key - `^]` - which is the only key the child never gets.

## The pieces

  * `tmux.jl`    sessions: name one, start it, tag it, list them, attach
  * `control.jl` `tmux -C`, as a protocol, as a client, and as the command pipe
  * `border.jl`  the box, in `TermInput`'s box characters and faces
  * `iframe.jl`  the widget: size, screen, cursor, mouse, scrollback, prefix

## What TermInput gives it

The border is `TermInput.CHROME[]`'s box and faces, so an iframe beside a
composer or a dialog is bordered the way they are, and its rows are
`TermInput`'s rows of faces, with a captured screen's row carried inside as a
verbatim piece - the child's raw SGR and OSC 8, as tmux gave them, never
measured. The measuring comes from there too. It lives in `TermInput` because
a text field needs exactly the same thing and must not pull a tmux binary in
to get it. What reads a screen's escapes at all is here, and only reads them:
`ESCAPE`, and `unescaped` for the text of a row.
"""
module TermIFrame

import tmux_jll
using Base64: base64encode
# Rows of faces, which is what the box is drawn as and what `TermInput`'s frame
# writes.
using TermInput
# Public in `TermInput` and not exported there, so imported by name: the box a
# border follows and the faces it is painted in, and the row it is drawn as.
import TermInput: boxstyle, CHROME, Row, row, verbatim

# Exported: what a host embedding a session writes, with names specific enough
# that it is unlikely to have them already - sessions by name, the command pipe
# and the iframe itself.
export mux_bin, no_mux, mux_name, mux_alive, mux_start, mux_kill, mux_tag!,
       mux_rename, mux_sessions, mux_list, MuxRow, mux_seen!, mux_ring!,
       mux_attach, mux_bg!, MUX_ENV, MUX_OLDER
export MuxClient, mux_wait, mux_pipe, mux_pipe_open, mux_pipe_close
export IFrame, iframe, iframe_box, iframe_origin, iframe_sync!, iframe_cursor,
       iframe_note, iframe_rows, iframe_input!, iframe_discard!, iframe_send!,
       iframe_close!, IFRAME_PREFIX

# Public and not exported: API, but a name a host is likely to have already -
# `mux`, `bordered`, `passthrough` - or the layer under the iframe, which a
# host driving a control client of its own reaches for and one showing an
# iframe never does. `import TermIFrame: bordered` where they are wanted.
# `public` is 1.11's, so it is parsed only where it exists.
@static if VERSION >= v"1.11.0-DEV.469"
    eval(Meta.parse("""public mux, mux_cmd, mux_spawn, mux_line, bundled_tmux,
        standalone, MUX_BG, MuxProto, mux_feed!, mux_unescape, passthrough,
        mux_open, mux_continue!, mux_relay!, mux_sync!, mux_ask, mux_capture,
        mux_pane_state, CopyMode, copy_selected, mux_paste, mux_brackets,
        mux_resize, mux_keys, mux_close, MUX_PIPE, MUX_BELLS, MUX_TITLES,
        pipe_session, mux_version, bordered, iframe_wheel!, page_keys!, iframe_drag!,
        retarget_mouse, WHEEL_ROWS, DRAG_SCROLL, PAUSE_AFTER, ESCAPE, unescaped"""))
end

include("tmux.jl")
include("control.jl")
include("border.jl")
include("iframe.jl")

end # module TermIFrame
