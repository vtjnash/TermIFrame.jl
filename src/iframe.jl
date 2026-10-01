# A child program, drawn inside a box.
#
# An iframe holds no idea of what its child is. It sizes a multiplexer session
# to the box it is drawn in, asks for the screen whenever the child writes
# anything, and prints what comes back. Nothing here reads what the child prints
# or names a key it might want, which is the whole point: `vi`, a pager and an
# agent are the same amount of work, and a program this does not know about is
# no work at all.
#
# Input is forwarded, not interpreted. The host hands the bytes over exactly as
# they arrived and they go straight to `send-keys -H`, so an arrow, a paste and
# a control character are all the same thing: bytes the child understands and
# this does not. Two things are held back. A mouse report is rewritten into the
# child's own coordinates, because the child owns a box inside a screen it knows
# nothing about; and `^]` is a prefix, because with every other key forwarded
# there would be no way out again.
#
# The host owns the layout. Every function here that needs geometry is told it,
# rather than asking `displaysize`: where the box is and how big it is are the
# host's answer to give, and an iframe beside something else is the case that
# matters.

"""A multiplexer session shown in a box.

`frame` is the last screen read back, one string per row with the escapes left
in. It is only ever replaced whole: a partial frame is not a thing tmux can
hand out, since `capture-pane` reads a grid that is always in a consistent
state, so there is no tearing to guard against and no need to wait for a redraw
to finish before drawing it.

It takes no functions from the host. What the host does about it is the host's,
from state it reads:

  * **redraw** when the client says something: [`mux_wait`](@ref) on `client`,
    which answers once more as the session ends.
  * **the child exited**: a sync that found the client dead leaves `client`
    `nothing` and says so in `status`. A child that *failed* is the same to
    the host, with the screen it left in `frame` and its status in `exited`:
    the server keeps its pane to be read ([`mux_start`](@ref)), and
    [`iframe_close!`](@ref) is what lets it go. Whatever the host does about it - an
    editor's file read back - is done once, by the host, which is the one that
    knows what once means.
  * **a key after the prefix**: [`iframe_input!`](@ref) answers it, and the
    host does what it means with the tools here - leaving, killing, going full
    screen with its own way of handing the terminal over ([`mux_attach`](@ref)).
"""
mutable struct IFrame
    name::String
    title::String
    client::Union{MuxClient,Nothing}
    frame::Vector{String}
    sized::Tuple{Int,Int}          # what the child was last told it had
    status::String
    pending::Bool                  # the prefix has been seen, its key has not
    cursor::Tuple{Int,Int,Bool}    # the child's cursor: x, y (0-based), showing
    wantsmouse::Bool               # the child asked for mouse reporting
    scroll::Int                    # rows back into the pane's history; 0 is live
    history::Int                   # how many rows there are to go back into
    alt::Bool                      # the child is on the alternate screen, where
                                   # scrolling back shows only its own redraws
    pasting::Bool                  # inside a bracketed paste, its end not seen
    brackets::Union{Nothing,Bool}  # the child wants the paste's markers, or
                                   # the server could not say and it is held
    paste::Vector{UInt8}           # the paste so far
    held::Vector{UInt8}            # the start of a marker a read cut through
    copy::Union{Nothing,CopyMode}  # tmux's copy mode, when the pane is in it
    press::Union{Nothing,Tuple{Int,Int}}  # where a button went down, in the
                                   # child's cells, until it comes up again
    dragging::Bool                 # that press has become a selection
    pointer::Tuple{Int,Int}        # where the drag is now, in the child's cells
    ticker::Union{Nothing,Timer}   # the next row of a drag held past an edge;
                                   # due once it has fired
    exited::Union{Nothing,Int}     # the child's exit status, when it failed and
                                   # the server kept its pane to show why
    childtitle::String             # the title the child set, drawn on the
                                   # border after `title`; "" where it never did
    out::IO                        # the terminal it is drawn on, which what the
                                   # child writes past the frame is relayed to
end

"""
    IFrame(name, title = ""; out = stdout) -> IFrame

An iframe with no child behind it. `out` is the terminal it is drawn on, as
for [`iframe`](@ref).

What one becomes when its child exits, and what a host's own key routing can be
built against without a server: everything that does not need the child - the
box, the footer, which keys are whose - answers the same way either way.
"""
IFrame(name::AbstractString, title::AbstractString = ""; out::IO = stdout) =
    IFrame(String(name), String(title), nothing, String[], (0, 0), "", false,
           (0, 0, false), false, 0, 0, false, false, nothing, UInt8[], UInt8[],
           nothing, nothing, false, (0, 0), nothing, nothing, "", out)

"""
    iframe(name, title; pause = PAUSE_AFTER, out = stdout) -> IFrame | Nothing

Open an iframe onto `name`, which must already be a running session - starting
one is [`mux_start`](@ref)'s job.

Returns `nothing` when there is no multiplexer or no such session, so the caller
can put a reason in its own status line rather than showing an empty box that
never explains itself.

The client is attached with `pause-after=pause`, in seconds: a host that stops
reading - its own terminal stopped taking bytes, and the write to it blocked the
process - has the pane paused and taken up again on its next sync
([`mux_continue!`](@ref)), where without it tmux drops the client once it is
five minutes behind and the pane says `session ended: the server said exit: too
far behind` over a session that is still running.

`out` is the terminal the iframe is drawn on - the host's, whatever stream it
writes its frames to. What the child writes that a frame cannot carry, the
clipboard, is relayed there ([`iframe_sync!`](@ref)).
"""
function iframe(name::AbstractString, title::AbstractString; pause::Integer = PAUSE_AFTER,
                out::IO = stdout)
    c = mux_open(name; flags = string("pause-after=", pause))
    c === nothing && return nothing
    IFrame(String(name), String(title), c, String[], (0, 0), "", false,
           (0, 0, false), false, 0, 0, false, false, nothing, UInt8[], UInt8[],
           nothing, nothing, false, (0, 0), nothing, nothing, "", out)
end

"""How long, in seconds, a pane's output can go unread before the server pauses
it for the iframe's client; see [`iframe`](@ref). Well short of the five minutes
after which a client without it is dropped, and long past any frame."""
const PAUSE_AFTER = 60

"""
    iframe_box(w, h) -> (cols, rows)

The child's usable size inside a box of `w` by `h`.

The border costs two rows and four columns - two of those columns are the
padding that keeps the child's own output off the frame - and one more row goes
to the footer that says where you are and what the keys do.
"""
iframe_box(w::Integer, h::Integer) = (max(1, Int(w) - 4), max(1, Int(h) - 3))

"""
    iframe_origin(x, y) -> (col, row)

Screen position of the child's top-left cell, 1-based, for an iframe whose own
top-left corner is at the 1-based `(x, y)`.

The border takes the first row and the first column, and the padding takes the
second column.
"""
iframe_origin(x::Integer, y::Integer) = (Int(x) + 2, Int(y) + 1)

"""
    iframe_sync!(f, box) -> Bool

Give the child the size it is being drawn at, `(cols, rows)` from
[`iframe_box`](@ref), and read its screen back.

Kept apart from drawing, which should be a pure function of what this leaves
behind: a host redraws far more often than the child changes.

Returns whether anything is worth redrawing, which for a live child is always.

What the child wrote that a redraw cannot carry - the clipboard, see
[`passthrough`](@ref) - is written here, to the iframe's `out`, the terminal
it is drawn on, where a person is looking. Here and not on the
reader: the host's own task, between its frames, is the one place nothing else
is writing.
"""
function iframe_sync!(f::IFrame, box::NTuple{2,Int})
    f.client === nothing && return false
    relay = mux_relay!(f.client)
    isempty(relay) || try
        foreach(seq -> print(f.out, seq), relay)
    catch
        # A closed `out` is the terminal going away, which the host will find
        # out about on its own.
    end
    # A pane the server paused while this was not reading is continued before
    # its screen is read, and the read is the resync.
    mux_continue!(f.client)
    if box != f.sized
        mux_resize(f.client, box[1], box[2]) && (f.sized = box)
    end
    # The state first, since copy mode says how far back to read: its view is
    # the one on screen while it is up, whatever our own scroll was.
    cx, cy, showing, mouse, hist, alt, copy, dead, f.childtitle = mux_pane_state(f.client)
    lines = mux_capture(f.client; scroll = copy === nothing ? f.scroll : copy.scroll,
                        rows = last(f.sized))
    if dead !== nothing && !f.client.dead
        # The child failed and the server kept its pane: the screen as it
        # died, tmux's `Pane is dead` line at its foot, is what is kept here,
        # and then the child is gone as any other is - nothing can be typed at
        # a dead pane. The session stays until the iframe lets go of it.
        f.frame = dead_screen(f.client, hist, last(f.sized))
        f.cursor, f.copy, f.scroll = (0, 0, false), nothing, 0
        f.exited = dead
        f.status = string("exited with status ", dead)
        mux_close(f.client)
        f.client = nothing
        return true
    end
    if f.client.dead
        # With the reason: a client that timed out on a reply is not a session
        # that ended, and the two want different things done about them.
        f.status = isempty(f.client.why) ? "session ended" :
                   string("session ended: ", f.client.why)
        f.client = nothing
        return true
    end
    # As tmux gave them: a row leaves a colour open into the next, which is
    # why the frame writer closes each one after it is written.
    f.frame = lines
    f.cursor, f.wantsmouse = (cx, cy, showing), mouse
    f.history, f.alt, f.copy = hist, alt, copy
    copy === nothing || paint_selection!(f.frame, copy, hist, first(f.sized))
    # The child rewriting its screen can shorten the history under a scroll that
    # was valid a moment ago, and the alternate screen going up ends the whole
    # question.
    f.scroll = alt ? 0 : clamp(f.scroll, 0, hist)
    # A drag held past an edge is a row further each time its ticker fires,
    # which is the wake that brought the host here - and only then, so output
    # from the child arriving meanwhile does not hurry it.
    if f.dragging && f.ticker !== nothing && !isopen(f.ticker)
        x, y = f.pointer
        drag_step!(f, y < 0, box)
        copy_goto(f, clamp(x, 0, first(box) - 1), clamp(y, 0, last(box) - 1))
        iframe_sync!(f, box)
    end
    true
end

"""
    ESCAPE

Matches a CSI sequence or an OSC 8 hyperlink at the start of a string - what
is in a captured row and takes no columns. `match(ESCAPE, SubString(s, i))` is
how a walk over a row steps over one. The one reader of a child's escapes:
nothing here turns them into anything else.
"""
const ESCAPE = r"^(?:\e\[[0-9;:]*[A-Za-z]|\e\][^\e]*\e\\)"

"""
    unescaped(row) -> String

A captured row with its escapes taken out: what the child's screen says there,
as against how it looks - what a copy counts characters in and what a blank
row is blank of.
"""
function unescaped(s::AbstractString)
    io, i = IOBuffer(), firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m === nothing
            write(io, s[i]); i = nextind(s, i)
        else
            i += ncodeunits(m.match)
        end
    end
    String(take!(io))
end

"""What a dead pane said, in `rows` rows: its history as well as its screen,
since the pane was resized to the box after it died and a box shorter than it
pushed its top lines - often the only ones with anything in them - into the
history. tmux writes `Pane is dead` on the bottom row, below however many
blank ones the screen had left; those are its padding and not the child's, so
they go, and the last `rows` lines are what is left.
"""
function dead_screen(c::MuxClient, hist::Int, rows::Int)
    lines = mux_capture(c; scroll = hist, rows = hist + rows)
    blank(l) = isempty(strip(unescaped(l)))
    while !isempty(lines) && blank(lines[end])
        pop!(lines)
    end
    if !isempty(lines)
        i = length(lines) - 1
        while i >= 1 && blank(lines[i])
            i -= 1
        end
        lines = vcat(lines[1:i], lines[end:end])
    end
    length(lines) > rows ? lines[end-rows+1:end] : lines
end

"""
    paint_selection!(rows, m, history, cols) -> rows

Draw copy mode's selection over the rows read back, which is the only way it
is ever seen: tmux draws it on the mode's screen, and `capture-pane` reads the
pane's. `rows` are the view `m` is scrolled to; which cells are selected is
[`copy_selected`](@ref)'s answer, the same rule tmux copies by.
"""
function paint_selection!(rows::Vector{String}, m::CopyMode, history::Int, cols::Int)
    m.sel === nothing && return rows
    for i in eachindex(rows)
        y = history - m.scroll + i - 1
        on = [copy_selected(m, x, y) for x in 0:cols-1]
        any(on) && (rows[i] = reverse_cells(rows[i], on))
    end
    rows
end

"""`s` with the cells `on` says drawn in reverse video, and past the end of
what it holds, the selected ones as reversed blanks - a line inside a
selection is selected to the edge, as it is in tmux. The reverse goes back on
after every escape in the run, since a reset there would end it."""
function reverse_cells(s::AbstractString, on::Vector{Bool})
    io, col, inside, i = IOBuffer(), 0, false, firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m === nothing
            want = get(on, col + 1, false)
            want == inside || (write(io, want ? "\e[7m" : "\e[27m"); inside = want)
            write(io, s[i])
            col += textwidth(s[i]); i = nextind(s, i)
        else
            write(io, m.match)
            inside && write(io, "\e[7m")
            i += ncodeunits(m.match)
        end
    end
    while col < length(on) && any(view(on, col+1:length(on)))
        want = on[col + 1]
        want == inside || (write(io, want ? "\e[7m" : "\e[27m"); inside = want)
        write(io, ' '); col += 1
    end
    inside && write(io, "\e[27m")
    String(take!(io))
end

"""
    iframe_cursor(f, origin, box) -> (row, col) | Nothing

Where the terminal's own cursor belongs, given the child's `origin` from
[`iframe_origin`](@ref) and its size from [`iframe_box`](@ref).

Row first, the other way round from `origin` and `box`, because it is an answer
for a different reader: those are read against mouse reports, which are `x;y`,
and this goes to `\e[row;colH`, which is not.

Putting the real cursor on the child's beats painting a facsimile, which cannot
blink and ignores whatever shape the user chose. Nothing when the child is
hiding it, when there is no child, or when it would land outside the box - a
cursor drawn over the border would be worse than none.
"""
function iframe_cursor(f::IFrame, origin::NTuple{2,Int}, box::NTuple{2,Int})
    cx, cy, showing = f.cursor
    if f.copy !== nothing
        # Copy mode's cursor is the one that means anything while it is up,
        # and it is always shown: it is where a selection's end is.
        (cx, cy), showing = f.copy.cursor, true
    elseif f.scroll > 0
        showing = false
    end
    (showing && f.client !== nothing) || return nothing
    cols, rows = box
    (0 <= cx < cols && 0 <= cy < rows) || return nothing
    ox, oy = origin
    (oy + cy, ox + cx)
end

"""
    iframe_note(f) -> String | Nothing

The footer row, when this has something of its own to say: where in the history
you are looking, or whatever was left in `status` - that the child has gone,
among others. `nothing` otherwise, which is when the host should say what its
own keys do; which keys those are is the host's to know.
"""
function iframe_note(f::IFrame)
    if f.copy !== nothing
        # tmux draws `[n/m]` in the corner of copy mode; this is that, and
        # the way out, since the keys are the mode's until it goes.
        return string(f.name, " · copy mode",
                      f.copy.scroll > 0 ? string(" · ", f.copy.scroll, " rows back of ", f.history) : "",
                      " · q leaves")
    elseif f.scroll > 0
        # Ahead of `status`, and it is the one thing that outranks it: a message
        # about something that just happened matters less than not knowing you
        # are looking at the past.
        return string(f.name, " · ", f.scroll, " rows back of ", f.history,
                      " · wheel down or any key returns")
    end
    isempty(f.status) ? nothing : f.status
end

"""
    iframe_rows(f, w, h; focused = true, note = nothing, box = boxstyle(),
                chrome = CHROME[]) -> Vector{Row}

The whole iframe: `h` rows of exactly `w` display columns, border and footer
included, each a `TermInput.Row` for its `frame_bytes`. A row of the child's
screen is in it as a verbatim piece, the child's escapes as the multiplexer
gave them, as wide as the inside of the box - which is what the pane was sized
to, so it is taken at that width and never measured. `note` overrides
[`iframe_note`](@ref), which is how a host puts its own keys on the last row.
`focused`, `box` and `chrome` are [`bordered`](@ref)'s, and the footer is
painted in the same `chrome`.
"""
function iframe_rows(f::IFrame, w::Int, h::Int; focused::Bool = true,
                     note = nothing, box = boxstyle(), chrome = CHROME[])
    # The child's title after the host's: the host's says which session this
    # is, the child's what is going on in it - an agent names its conversation
    # there. Cut from the right by `bordered`, so the host's is what stays.
    title = isempty(f.childtitle) ? f.title : string(f.title, "  \u00b7  ", f.childtitle)
    inner = max(0, w - 4)
    body = bordered(Row[verbatim(l, inner) for l in f.frame], w, h - 1, title;
                    focused, box, chrome)
    n = note === nothing ? iframe_note(f) : note
    n === nothing && (n = f.name)
    rows = vcat(body, Row[faced(rowfit(n, w), chrome.quiet)])
    while length(rows) < h
        push!(rows, row(""))
    end
    Row[rowpad(r, w) for r in rows[1:h]]
end

"""Ctrl-] is the prefix, and the only key the child never gets.

While the child has the keyboard everything else is its own, Escape and Ctrl-C
included, so the way in cannot be a key a program would want. Ctrl-] is
telnet's, for the same reason, and almost nothing binds it.

It has to be a prefix and not simply an escape. With every key forwarded, a lone
escape key leaves no way to reach anything else the host can do - killing the
session, going full screen - which were reachable only after the child had
already died. One prefix gives all of them back.

This package finds it and nothing more: [`iframe_input!`](@ref) answers the key
typed after it, and what that key means is the host's. The finding is here
because the prefix is in the same stream as everything else - a `^]` inside a
paste is text, and the prefix can end one read with its key in the next.

Written without a space - `^]a`, not `^] a` - because in a line of prose that
names several of them, a lone `a` reads as the word.
"""
const IFRAME_PREFIX = 0x1d

"""How far one notch of the wheel moves, in rows."""
const WHEEL_ROWS = 3

"""How long a drag held past the top or bottom of the box waits between rows,
in seconds. A rate of its own, as in every terminal: one row per motion
reported scrolls only while the pointer moves, and as fast as it does."""
const DRAG_SCROLL = Ref(0.025)

"""
    iframe_wheel!(f, b) -> Bool

Answer a wheel report the child did not want, by moving our own window over the
pane's history. `b` is the SGR button number.

The modifier bits are stripped rather than matched, so shift- and ctrl-wheel
scroll like the plain one instead of falling through as nothing - a modifier is
a refinement of a request and never a different request.

Refused on the alternate screen, and that is the point rather than a caveat:
what is behind a full-screen program is the wreckage of its own redraws, and
scrolling into it shows something that was never a screen. It is why terminals
stop offering scrollback while one is up, and why a nested tmux gets nothing
from this.
"""
function iframe_wheel!(f::IFrame, b::Int)
    d = (b & ~0x1c)                    # shift, meta and ctrl are not the button
    if f.copy !== nothing
        # Copy mode has a view of its own, which is the one on screen: the
        # wheel moves that, as it would in tmux.
        (d == 64 || d == 65) || return false
        copy_cmd(f, d == 64 ? "scroll-up" : "scroll-down", WHEEL_ROWS)
        iframe_sync!(f, f.sized)
        return true
    end
    f.alt && return false
    d == 64 ? (f.scroll = clamp(f.scroll + WHEEL_ROWS, 0, f.history); true) :
    d == 65 ? (f.scroll = clamp(f.scroll - WHEEL_ROWS, 0, f.history); true) :
              false
end

"""
    page_keys!(f, bytes) -> (bytes, Bool)

Take the shifted and controlled page keys (`\\e[5;2~`, `\\e[6;5~` and the like)
out of `bytes` and answer them here, a page of the pane's history at a time,
as the wheel is answered - and say whether the view moved.

A terminal keeps these for its own scrollback, and a shell has nothing bound
to them: sent on, readline prints the tail of the sequence, `5~`, at the
prompt. On the alternate screen they are left for the child, which may bind
them - a pager, an editor's tabs - and has no history behind it to show.
"""
function page_keys!(f::IFrame, bytes::Vector{UInt8})
    (f.copy === nothing && f.alt) && return (bytes, false)
    moved = false
    out = UInt8[]
    i = 1
    while i <= length(bytes)
        if i + 5 <= length(bytes) && bytes[i] == 0x1b && bytes[i+1] == UInt8('[') &&
           bytes[i+2] in (UInt8('5'), UInt8('6')) && bytes[i+3] == UInt8(';') &&
           bytes[i+4] in (UInt8('2'), UInt8('5'), UInt8('6')) && bytes[i+5] == UInt8('~')
            up = bytes[i+2] == UInt8('5')
            page = max(1, last(f.sized) - 1)
            if f.copy !== nothing
                copy_cmd(f, up ? "scroll-up" : "scroll-down", page)
            else
                f.scroll = clamp(f.scroll + (up ? page : -page), 0, f.history)
            end
            moved = true
            i += 6
        else
            push!(out, bytes[i])
            i += 1
        end
    end
    (out, moved)
end

"""
    retarget_mouse(f, bytes, origin, box) -> Vector{UInt8}

Rewrite the mouse reports in `bytes` for the child, or answer them here.

This is the one thing that cannot be forwarded untouched, and both reasons are
worth stating.

A report arrives in *screen* coordinates, but the child owns a box inside that
screen, offset by whatever is drawn to its left and by its own border. Sent on
unchanged, a click lands wherever the arithmetic happens to put it - which is
somewhere else, and usually plausibly so.

And a report means nothing to a program that never asked for one. `send-keys`
puts these bytes into the pane's pty as *input*, so tmux never sees them as
mouse events and its own `mouse` setting has no bearing: an application that has
not turned mouse reporting on receives the escape sequence and prints it, which
is exactly the control characters that show up on the screen. So the child is
asked, through `mouse_any_flag`, and told nothing it did not ask for.

Only the SGR form (`\\e[<b;x;yM`) is understood, which is the only form worth
asking a terminal for.
"""
function retarget_mouse(f::IFrame, bytes::Vector{UInt8}, origin::NTuple{2,Int},
                        box::NTuple{2,Int})
    occursin("\e[<", String(copy(bytes))) || return bytes
    ox, oy = origin
    cols, rows = box
    out, i, n = UInt8[], 1, length(bytes)
    while i <= n
        # ESC [ < ... (M|m)
        if bytes[i] == 0x1b && i + 2 <= n && bytes[i+1] == UInt8('[') && bytes[i+2] == UInt8('<')
            j = i + 3
            while j <= n && bytes[j] != UInt8('M') && bytes[j] != UInt8('m')
                j += 1
            end
            if j <= n
                fs = split(String(bytes[i+3:j-1]), ';')
                nums = length(fs) == 3 ? tryparse.(Int, fs) : nothing
                if nums !== nothing && !any(isnothing, nums)
                    b, sx, sy = nums
                    cx, cy = sx - ox, sy - oy      # 0-based within the child
                    inside = 0 <= cx < cols && 0 <= cy < rows
                    down = bytes[j] == UInt8('M')
                    if f.wantsmouse && inside && !f.dragging
                        append!(out, codeunits(string("\e[<", b, ";", cx + 1, ";",
                                                      cy + 1, Char(bytes[j]))))
                    elseif b & 64 != 0
                        # The child did not ask for the mouse, so a wheel over it
                        # is ours to answer - and this is the only scrollback an
                        # iframe has. Nothing else can offer one: `capture-pane`
                        # reads the grid, so a box showing a shell that has just
                        # printed a build log had no way at all to look back at
                        # it.
                        inside && down && iframe_wheel!(f, b)
                    elseif inside || f.press !== nothing
                        # And a drag over it is tmux's copy mode - outside the
                        # box too once one has begun, since that is where a
                        # drag goes to scroll and a button comes up.
                        iframe_drag!(f, b, cx, cy, down, box)
                    end
                    i = j + 1
                    continue
                elseif length(fs) == 3 && !in(0x1b, view(bytes, i+3:j-1))
                    # A report with its numbers missing - xterm.js sends
                    # `\e[<0;NaN;NaNm` for a button let go over a terminal
                    # it cannot place, a pane not on screen - is still a
                    # report, and no child asked for it as text: passed on,
                    # a shell prints `0;NaN;NaNm`.
                    i = j + 1
                    continue
                end
            end
        end
        push!(out, bytes[i]); i += 1
    end
    out
end

"""
    iframe_drag!(f, b, x, y, down, box)

A left-button drag over a child that did not ask for the mouse, as tmux's copy
mode: what tmux would do with it on a terminal of its own, done through the
mode's commands, since a control client has no way to hand tmux the drag
itself. `(x, y)` is the child's cell, 0-based, and may be outside the box once
a drag has begun. `down` is false for the button coming up.

A press alone is nothing, as in tmux: copy mode starts on the first motion,
at the cell pressed, and each motion after moves the selection's end there.
Past the top or the bottom it scrolls a row at once, and then a row every
[`DRAG_SCROLL`](@ref) until the pointer is back over the box or the button
comes up, whether or not it moves: a timer wakes the client, and the sync
that wake brings takes the step ([`iframe_sync!`](@ref)). The button coming up
copies it, into tmux's buffers and onto the terminal's clipboard, and leaves
the mode, and the view stays where the mode had got to.

What is copied is tmux's to say, and that is the reason for all of this: it
knows a wrapped line from two, and joins the one.
"""
function iframe_drag!(f::IFrame, b::Int, x::Int, y::Int, down::Bool,
                      box::NTuple{2,Int})
    f.client === nothing && return
    btn = b & ~0x1c
    cols, rows = box
    if !down
        drag_held!(f, false)
        f.dragging && copy_finish!(f, box)
        f.press, f.dragging = nothing, false
    elseif btn == 0
        f.press, f.dragging = (0 <= x < cols && 0 <= y < rows) ? (x, y) : nothing, false
    elseif btn == 32 && f.press !== nothing
        if !f.dragging
            if !copy_cmd(f, "")
                f.press = nothing
                return
            end
            f.dragging = true
            f.scroll > 0 && copy_cmd(f, "scroll-up", f.scroll)
            copy_goto(f, f.press...)
            copy_cmd(f, "begin-selection")
        end
        f.pointer = (x, y)
        past = y < 0 || y >= rows
        # The first motion past an edge scrolls; the ones after it only move
        # across, and the ticker scrolls.
        past && f.ticker === nothing && drag_step!(f, y < 0, box)
        drag_held!(f, past)
        copy_goto(f, clamp(x, 0, cols - 1), clamp(y, 0, rows - 1))
        iframe_sync!(f, box)
    end
    nothing
end

"""One row of a drag past an edge: the mode's view scrolled, the screen read
back - the row the cursor goes to is a new one, and its width is what a column
is clamped to - and the ticker armed for the next."""
function drag_step!(f::IFrame, up::Bool, box::NTuple{2,Int})
    copy_cmd(f, up ? "scroll-up" : "scroll-down")
    drag_held!(f, false)
    c = f.client
    c === nothing && return
    # Armed before the sync, so the sync finds it not yet due.
    f.ticker = Timer(_ -> notify(c.wake), DRAG_SCROLL[])
    iframe_sync!(f, box)
end

"""The pointer is past an edge, or it is not: when not, the ticker stops."""
function drag_held!(f::IFrame, past::Bool)
    past && return
    f.ticker === nothing || close(f.ticker)
    f.ticker = nothing
end

"""One copy-mode command to the pane: `send -X`, repeated `n` times, or with
an empty `cmd` the entering of the mode itself. One to an ask, never a `;`
list: each command in a list is answered on its own, and the answers are
matched to the asking by position."""
function copy_cmd(f::IFrame, cmd::AbstractString, n::Int = 1)
    f.client === nothing && return false
    n > 0 || return true
    t = string(" -t =", f.name, ":")
    first(mux_ask(f.client, isempty(cmd) ? string("copy-mode", t) :
                  string("send -X", n > 1 ? string(" -N ", n) : "", t, " ", cmd)))
end

"""Put copy mode's cursor on cell `(x, y)` of its view.

There is no command for a cell, so it is the top row, down `y`, and then
across. Across is from wherever that left the cursor, which is asked: a step
down goes to a remembered column that `top-line` does not reset when the top
row is empty, and `start-of-line` on the second row of a wrapped line goes to
where the line starts, a row up. It is counted in characters, since a step
skips the padding of a wide one, and clamped to the line's end, since one step
past it wraps to the next row.
"""
function copy_goto(f::IFrame, x::Int, y::Int)
    copy_cmd(f, "top-line")
    copy_cmd(f, "cursor-down", y)
    ok, st = mux_ask(f.client, string("display-message -p -t =", f.name, ": '#{copy_cursor_x}'"))
    at = ok && !isempty(st) ? something(tryparse(Int, strip(st[1])), 0) : 0
    line = y + 1 <= length(f.frame) ? rstrip(unescaped(f.frame[y + 1])) : ""
    d = chars_before(line, x) - chars_before(line, at)
    d > 0 ? copy_cmd(f, "cursor-right", d) : copy_cmd(f, "cursor-left", -d)
end

"""How many characters of `line` start before column `x`: the steps from its
start to the cell at `x`, or to its end when `x` is past it."""
function chars_before(line::AbstractString, x::Int)
    k, col = 0, 0
    for c in line
        col >= x && break
        k += 1; col += textwidth(c)
    end
    k
end

"""The button coming up: copy what is selected and leave the mode. The text
goes on the terminal's clipboard the way a child's own OSC 52 does, relayed
at the next sync - a control client has no terminal for tmux's
`set-clipboard` to reach."""
function copy_finish!(f::IFrame, box::NTuple{2,Int})
    c = f.client
    c === nothing && return
    t = string(" -t =", f.name, ":")
    ok, st = mux_ask(c, string("display-message -p", t, " '#{selection_present},#{scroll_position}'"))
    fs = ok && !isempty(st) ? split(st[1], ',') : String[]
    present = length(fs) == 2 && fs[1] == "1"
    back = length(fs) == 2 ? something(tryparse(Int, fs[2]), 0) : 0
    if present && copy_cmd(f, "copy-selection-and-cancel")
        ok, buf = mux_ask(c, "show-buffer")
        ok && push!(c.relay, string(OSC52, "c;", base64encode(join(buf, "\n")), "\a"))
    else
        copy_cmd(f, "cancel")
    end
    # Where the mode had got to is where the view stays.
    f.scroll = back
    iframe_sync!(f, box)
end

const PASTE_START = b"\e[200~"
const PASTE_END = b"\e[201~"

"""How many bytes at the end of `bytes` are the start of `marker` - a read cut
through it - counting only a start at least `least` long."""
function cut_marker(bytes::AbstractVector{UInt8}, marker::AbstractVector{UInt8}, least::Int)
    for k in min(length(marker) - 1, length(bytes)):-1:least
        view(bytes, length(bytes)-k+1:length(bytes)) == view(marker, 1:k) && return k
    end
    0
end

"""Typing snaps back to the live screen, the way every terminal does - what
you type is going to the bottom of it, so that is where you want to be
looking."""
function live!(f::IFrame, box::NTuple{2,Int})
    f.scroll == 0 && return
    f.scroll = 0
    iframe_sync!(f, box)
end

"""
    iframe_input!(f, bytes, origin, box) -> :ok | :gone | UInt8

Bytes as typed, straight through to the child, up to the key after a prefix.

No key is named, and the only sequence read on the way is a mouse report, whose
coordinates have to be moved into the child's box - see [`retarget_mouse`](@ref).
So this is the same amount of code whether the child is a shell, `vi` or
something not yet written.

The prefix is the one byte held back rather than forwarded, and it is tracked
across bursts: it can arrive alone, or ahead of its key in the same read. The
key after it is the answer, a `UInt8`, for the host to act on: everything typed
before the prefix has gone to the child, and everything read after the key is
kept, to go on the next call - which is the host's to make once it has answered
the key, with no bytes of its own, unless the key took it somewhere else, when
[`iframe_discard!`](@ref) lets them go. The
tools for the answers are here - [`iframe_close!`](@ref), [`mux_kill`](@ref),
[`mux_attach`](@ref), [`iframe_sync!`](@ref), [`iframe_send!`](@ref) for the
prefix itself - and which key is which is the host's.

`:gone` is an iframe with no child any more; the host decides what that means.
A key that finds the client dead is `:ok`: it is spent on saying the session
ended, as a sync would have, and the next one is `:gone`.

**A bracketed paste is text, not keys.** A host that turns bracketed paste on
for its own sake - so that a paste is never read as its commands - hands the
markers on here with the rest, and whether *this* child wanted them is the
child's business. It is asked once, as the paste starts
([`mux_brackets`](@ref)): the paste then streams through as it arrives, with
the markers where the child set `?2004` and without them where it did not.
Where the server is too old to say, the paste is held until its end marker
and goes whole through [`mux_paste`](@ref), which brackets it only where the
child asked. Nothing inside a paste is a prefix or a mouse report, and a
marker cut in two by a read is put back together.
"""
function iframe_input!(f::IFrame, bytes::Vector{UInt8}, origin::NTuple{2,Int},
                       box::NTuple{2,Int})
    f.client === nothing && return :gone
    # A key that finds the client dead is the first the host has heard of it,
    # when no wake said so: it is spent on saying the session ended, as a
    # sync would have, and the next one leaves - rather than going to a
    # client that cannot send it, forever.
    f.client.dead && (iframe_sync!(f, box); return :ok)
    if !isempty(f.held)
        bytes = vcat(f.held, bytes)
        empty!(f.held)
    end
    i = 1
    while i <= length(bytes)
        if f.pasting
            j = findnext(PASTE_END, bytes, i)
            stop = j === nothing ? length(bytes) : first(j) - 1
            k = j === nothing ? cut_marker(view(bytes, i:stop), PASTE_END, 1) : 0
            append!(f.paste, view(bytes, i:stop-k))
            append!(f.held, view(bytes, stop-k+1:stop))
            if j !== nothing
                f.pasting = false
                f.brackets === true && append!(f.paste, PASTE_END)
            end
            if f.brackets !== nothing || j !== nothing
                live!(f, box)
                f.client === nothing ? nothing :
                f.brackets === nothing ? mux_paste(f.client, f.paste) :
                                         mux_keys(f.client, f.paste)
                empty!(f.paste)
            end
            j === nothing && return :ok
            i = last(j) + 1
        else
            j = findnext(PASTE_START, bytes, i)
            stop = j === nothing ? length(bytes) : first(j) - 1
            # Only a cut that has got as far as `ESC [ 2` is held: a lone
            # escape at the end of a read is the escape key, and holding it
            # would hold the key.
            k = j === nothing ? cut_marker(view(bytes, i:stop), PASTE_START, 3) : 0
            k > 0 && append!(f.held, view(bytes, stop-k+1:stop))
            seg = bytes[i:stop-k]
            p = typed_input!(f, seg, origin, box)
            if p > 0
                # The key after the prefix. What follows it is kept raw, as it
                # was read - mouse reports not yet moved, a paste not yet begun.
                f.held = bytes[i+p:end]
                return seg[p]
            end
            j === nothing && break
            f.pasting = true
            f.brackets = f.client === nothing ? nothing : mux_brackets(f.client)
            f.brackets === true && append!(f.paste, PASTE_START)
            i = last(j) + 1
        end
    end
    :ok
end

"""What was typed, as opposed to pasted, up to a prefix: answers where in
`bytes` the key after the prefix is, or 0 when there is none - everything went
to the child, or the prefix ended the read and its key is still to come."""
function typed_input!(f::IFrame, bytes::Vector{UInt8}, origin::NTuple{2,Int},
                      box::NTuple{2,Int})
    isempty(bytes) && return 0
    f.pending && (f.pending = false; return 1)
    # Split before the mouse reports are moved, which a prefix is never inside:
    # the bytes after a key go round again, and must be moved once.
    j = findfirst(==(IFRAME_PREFIX), bytes)
    typed_send!(f, j === nothing ? bytes : bytes[1:j-1], origin, box)
    j === nothing && return 0
    j == length(bytes) && (f.pending = true; return 0)
    j + 1
end

"""Typed bytes to the child: mouse reports moved or answered, and the live
screen back first."""
function typed_send!(f::IFrame, bytes::Vector{UInt8}, origin::NTuple{2,Int},
                     box::NTuple{2,Int})
    isempty(bytes) && return
    was = f.scroll
    bytes = retarget_mouse(f, bytes, origin, box)
    (bytes, paged) = page_keys!(f, bytes)
    # A scroll is only a different window on the same pane, so nothing wakes to
    # say it happened: the re-read has to be asked for here.
    (paged || f.scroll != was) && iframe_sync!(f, box)
    iframe_send!(f, bytes, box)
    nothing
end

"""
    iframe_send!(f, bytes, box) -> Bool

Send `bytes` to the child as keys, back on the live screen first. What a host
sends for `^]]`: the prefix itself, which [`iframe_input!`](@ref) never does.
"""
function iframe_send!(f::IFrame, bytes::AbstractVector{UInt8}, box::NTuple{2,Int})
    isempty(bytes) && return true
    live!(f, box)
    f.client === nothing && return false
    mux_keys(f.client, bytes)
end

"""
    iframe_discard!(f)

Drop what was read after the key [`iframe_input!`](@ref) answered, for a host
whose answer took the keyboard somewhere else: those bytes were typed at
wherever the keys went, and sent to the child on the next call they would land
in a program the person had already left.
"""
function iframe_discard!(f::IFrame)
    empty!(f.held)
    nothing
end

"""
    iframe_close!(f)

Let go of the child. The session keeps running - that is what a session is for;
[`mux_kill`](@ref) is what ends one. Unless the child failed and its pane was
kept for this (`exited`): once it has been seen there is nothing left running,
and letting go of it is ending it.
"""
function iframe_close!(f::IFrame)
    drag_held!(f, false)
    f.client === nothing || mux_close(f.client)
    f.exited === nothing || (mux_kill(f.name); f.exited = nothing)
    nothing
end
