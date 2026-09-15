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
    f = iframe("demo", "htop"; onwake = () -> redraw())

    cols, rows = iframe_box(w, h)          # the child's size inside your box
    iframe_sync!(f, cols, rows)            # size it, read its screen
    rows_to_print = iframe_rows(f, w, h)   # `h` rows of exactly `w` columns
    iframe_input!(f, bytes, iframe_origin(x, y), (cols, rows))

The host owns the layout: nothing here asks `displaysize`, because an iframe
drawn beside something else is the case that matters. What it owns instead is
the box, the child's coordinates, the scrollback the child does not provide, and
one prefix key - `^]` - which is the only key the child never gets.

## The pieces

  * `tmux.jl`    sessions: name one, start it, tag it, list them, attach
  * `control.jl` `tmux -C`, as a protocol and as a client
  * `border.jl`  the box, in Term's box characters and the theme's style
  * `iframe.jl`  the widget: size, screen, cursor, mouse, scrollback, prefix

## What Term gives it

The border follows `Term.TERM_THEME[].box`, so an iframe beside a `Term.Panel`
is bordered the way that panel is. The measuring is not Term's: `Panel` measures
markup, and a captured screen is a child program's raw SGR and OSC 8, which
markup measurement counts as characters - content that fits is wrapped, and the
panel then elides its own tail. It comes from `TermInput` instead - `awidth`,
`astrip`, `afit`, `apad`, `amid` and `awrap`, re-exported here - which is where
it lives because a text field needs exactly the same thing and must not pull a
tmux binary in to get it.
"""
module TermIFrame

import tmux_jll
# The escape-aware measuring, which is `TermInput`'s and re-exported below: a
# host laying an iframe out beside something else needs it as much as this does.
using TermInput

export ESCAPE, awidth, astrip, afit, apad, amid, awrap
export mux_bin, mux_cmd, bundled_tmux, no_mux, mux_name, mux, mux_alive, mux_start, mux_kill, mux_tag!,
       mux_rename, mux_sessions, mux_list, mux_attach, standalone,
       MUX_PREFIX, MUX_ENV, SCRUB_PREFIXES
export MuxProto, mux_feed!, mux_unescape, passthrough
export MuxClient, mux_open, mux_sync!, mux_ask, mux_capture, mux_pane_state,
       mux_resize, mux_keys, mux_close
export bordered
export IFrame, iframe, iframe_box, iframe_origin, iframe_sync!, iframe_cursor,
       iframe_note, iframe_rows, iframe_command!, iframe_input!, iframe_close!,
       iframe_keys, iframe_wheel!, retarget_mouse,
       IFRAME_PREFIX, IFRAME_KEYS, WHEEL_ROWS

include("tmux.jl")
include("control.jl")
include("border.jl")
include("iframe.jl")

end # module TermIFrame
