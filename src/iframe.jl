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

The callbacks are how a host gets its own behaviour in without this knowing
about it:

  * `onwake`  — the child wrote something, or the session ended; redraw. Runs
                on the reader task.
  * `onend`   — called once, when the child exits. A `String` becomes the status.
  * `suspend` — hand the whole terminal over, for `^]a`; see [`mux_attach`](@ref).
  * `onerror` — `(exception, backtrace, what)`, for a host with somewhere to log.
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
    onend::Any
    suspend::Any
    onerror::Any
end

"""
    IFrame(name, title = "") -> IFrame

An iframe with no child behind it.

What one becomes when its child exits, and what a host's own key routing can be
built against without a server: everything that does not need the child - the
box, the footer, which keys are whose - answers the same way either way.
"""
IFrame(name::AbstractString, title::AbstractString = "") =
    IFrame(String(name), String(title), nothing, String[], (0, 0), "", false,
           (0, 0, false), false, 0, 0, false, false, nothing, UInt8[], UInt8[],
           nothing, g -> g(), nothing)

"""
    iframe(name, title; onwake, onend, suspend, onerror) -> IFrame | Nothing

Open an iframe onto `name`, which must already be a running session - starting
one is [`mux_start`](@ref)'s job.

Returns `nothing` when there is no multiplexer or no such session, so the caller
can put a reason in its own status line rather than showing an empty box that
never explains itself.
"""
function iframe(name::AbstractString, title::AbstractString;
                onwake = nothing, onend = nothing, suspend = f -> f(),
                onerror = nothing)
    # Two things per burst of output: redraw, and relay what a redraw cannot
    # carry - which is the clipboard and nothing else, for the reasons in
    # `passthrough`. It goes to this process's own stdout, where the terminal a
    # person is actually looking at is the next thing up.
    #
    # This runs on the reader task, so it can land in the middle of the host
    # writing a frame. That is safe for exactly the reason only OSC 52 is
    # relayed: the sequence paints nothing and moves no cursor, so wherever it
    # arrives in the stream it changes nothing about what the frame draws.
    #
    # One carry per pane: an `%output` line is a cut of one pane's stream, and
    # a clipboard longer than the cut finishes on a later line - see
    # `passthrough`.
    carry = Dict{String,Base.RefValue{String}}()
    c = mux_open(name; onoutput = (pane, bytes) -> begin
        try
            for seq in passthrough(get!(() -> Ref(""), carry, pane), bytes)
                print(seq)
            end
        catch
            # A closed stdout is the terminal going away, which the host will
            # find out about on its own. It must not take the reader down too.
        end
        onwake === nothing || onwake()
    end,
    # And once more when it ends, so the host syncs and finds it gone.
    ondead = onwake)
    c === nothing && return nothing
    IFrame(String(name), String(title), c, String[], (0, 0), "", false,
           (0, 0, false), false, 0, 0, false, false, nothing, UInt8[], UInt8[],
           onend, suspend, onerror)
end

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
    iframe_sync!(f, cols, rows) -> Bool

Give the child the size it is being drawn at, and read its screen back.

Kept apart from drawing, which should be a pure function of what this leaves
behind: a host redraws far more often than the child changes.

Returns whether anything is worth redrawing, which for a live child is always.
"""
function iframe_sync!(f::IFrame, cols::Integer, rows::Integer)
    f.client === nothing && return false
    box = (Int(cols), Int(rows))
    if box != f.sized
        mux_resize(f.client, box[1], box[2]) && (f.sized = box)
    end
    lines = mux_capture(f.client; scroll = f.scroll, rows = last(f.sized))
    if f.client.dead
        # With the reason: a client that timed out on a reply is not a session
        # that ended, and the two want different things done about them.
        f.status = isempty(f.client.why) ? "session ended" :
                   string("session ended: ", f.client.why)
        f.client = nothing
        # Once, and never from a later sync: an editor's file is read back when
        # it exits, and reading it twice would undo an edit made in between.
        if f.onend !== nothing
            g, f.onend = f.onend, nothing
            r = try
                g()
            catch e
                f.onerror === nothing || f.onerror(e, catch_backtrace(), "iframe onend")
                "the child's result could not be taken"
            end
            r isa String && !isempty(r) && (f.status = r)
        end
        return true
    end
    # Every row is closed off, or an unterminated colour would run out of the
    # content and into the border and padding.
    f.frame = [string(l, "\e[0m") for l in lines]
    cx, cy, showing, mouse, hist, alt = mux_pane_state(f.client)
    f.cursor, f.wantsmouse = (cx, cy, showing), mouse
    f.history, f.alt = hist, alt
    # The child rewriting its screen can shorten the history under a scroll that
    # was valid a moment ago, and the alternate screen going up ends the whole
    # question.
    f.scroll = alt ? 0 : clamp(f.scroll, 0, hist)
    true
end

"""
    iframe_cursor(f, origin, box) -> (row, col) | Nothing

Where the terminal's own cursor belongs, given the child's `origin` from
[`iframe_origin`](@ref) and its size from [`iframe_box`](@ref).

Putting the real cursor on the child's beats painting a facsimile, which cannot
blink and ignores whatever shape the user chose. Nothing when the child is
hiding it, when there is no child, or when it would land outside the box - a
cursor drawn over the border would be worse than none.
"""
function iframe_cursor(f::IFrame, origin::NTuple{2,Int}, box::NTuple{2,Int})
    cx, cy, showing = f.cursor
    (showing && f.client !== nothing && f.scroll == 0) || return nothing
    cols, rows = box
    (0 <= cx < cols && 0 <= cy < rows) || return nothing
    ox, oy = origin
    (oy + cy, ox + cx)
end

"""
    iframe_note(f) -> String | Nothing

The footer row, when this has something of its own to say: where in the history
you are looking, whatever the last key left in `status`, or that the child has
gone. `nothing` when the child is live and quiet, which is when the host should
say what its own keys do.
"""
function iframe_note(f::IFrame)
    if f.scroll > 0
        # Ahead of `status`, and it is the one thing that outranks it: a message
        # about something that just happened matters less than not knowing you
        # are looking at the past.
        return string(f.name, " · ", f.scroll, " rows back of ", f.history,
                      " · wheel down or any key returns")
    end
    isempty(f.status) || return f.status
    f.client === nothing &&
        return string(f.name, " · q to leave · K to kill it")
    nothing
end

"""
    iframe_rows(f, w, h; focused, note) -> Vector{String}

The whole iframe: `h` rows of exactly `w` display columns, border and footer
included. `note` overrides [`iframe_note`](@ref), which is how a host puts its
own keys on the last row.
"""
function iframe_rows(f::IFrame, w::Int, h::Int; focused::Bool = true,
                     note = nothing)
    body = bordered(f.frame, w, h - 1, f.title, focused)
    n = note === nothing ? iframe_note(f) : note
    n === nothing && (n = string(f.name, " · ^]q leave it running · ^]? keys"))
    rows = vcat(body, [string(CHROME[].quiet, afit(String(n), w), CHROME[].reset)])
    while length(rows) < h
        push!(rows, "")
    end
    [apad(r, w) for r in rows[1:h]]
end

"""Ctrl-] is the prefix, and the only key the child never gets.

While the child has the keyboard everything else is its own, Escape and Ctrl-C
included, so the way in cannot be a key a program would want. Ctrl-] is
telnet's, for the same reason, and almost nothing binds it.

It has to be a prefix and not simply an escape. With every key forwarded, a lone
escape key leaves no way to reach anything else the host can do - killing the
session, going full screen - which were reachable only after the child had
already died. One prefix gives all of them back.

Written without a space - `^]a`, not `^] a` - because in a line of prose that
names several of them, a lone `a` reads as the word.
"""
const IFRAME_PREFIX = 0x1d

"""The bytes after the prefix that this package answers, and a host must not
shadow: `q`, Escape and Tab leave, `K` kills, `a` goes full screen, `r` rereads,
`^]` and `]` send a literal prefix through, and `?` asks what they all are.

A host's `oncommand` is asked *first*, so that a key it wants - `^]tab` for
something drawn beside the child - can be taken back. This is the list to check
against before doing so.
"""
const IFRAME_KEYS = (UInt8('q'), 0x1b, UInt8('\t'), UInt8('K'), UInt8('a'),
                     UInt8('r'), IFRAME_PREFIX, UInt8(']'), UInt8('?'))

"""What the prefix is for, spelled out. `^]?` asks for it."""
iframe_keys() =
    "^]q leave · ^]K kill · ^]a full screen · ^]r reread · ^]] literal"

"""
    iframe_command!(f, b, box; oncommand) -> :ok | :pop | :literal

One key after the prefix. `box` is the child's current size, since two of these
keys re-read the screen and the size to read it at is the host's to say - the
terminal may have been resized while `^]a` had it.

`oncommand` is the host's, called with the byte and returning `:ok`, `:pop` or
`:unhandled`; it is asked first so a host can claim a key, and must leave
[`IFRAME_KEYS`](@ref) alone. `:literal` means send the prefix itself through to
the child.
"""
function iframe_command!(f::IFrame, b::UInt8, box::NTuple{2,Int};
                         oncommand = nothing)
    if oncommand !== nothing
        r = oncommand(b)
        r === :unhandled || return r
    end
    if b == UInt8('q') || b == 0x1b || b == UInt8('\t')
        # Escape and tab too, and not only `q`: a key that means "out of here"
        # everywhere else should not be one the prefix has no answer for.
        iframe_close!(f)
        :pop
    elseif b == UInt8('K')
        iframe_close!(f)
        mux_kill(f.name)
        :pop
    elseif b == UInt8('a')
        mux_attach(f.name; suspend = f.suspend)
        iframe_sync!(f, box...)
        :ok
    elseif b == UInt8('r')
        iframe_sync!(f, box...)
        :ok
    elseif b == IFRAME_PREFIX || b == UInt8(']')
        :literal
    else
        f.status = iframe_keys()
        :ok
    end
end

"""How far one notch of the wheel moves, in rows."""
const WHEEL_ROWS = 3

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
    f.alt && return false
    d = (b & ~0x1c)                    # shift, meta and ctrl are not the button
    d == 64 ? (f.scroll = clamp(f.scroll + WHEEL_ROWS, 0, f.history); true) :
    d == 65 ? (f.scroll = clamp(f.scroll - WHEEL_ROWS, 0, f.history); true) :
              false
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
                    if f.wantsmouse && inside
                        append!(out, codeunits(string("\e[<", b, ";", cx + 1, ";",
                                                      cy + 1, Char(bytes[j]))))
                    elseif inside && bytes[j] == UInt8('M')
                        # The child did not ask for the mouse, so a wheel over it
                        # is ours to answer - and this is the only scrollback an
                        # iframe has. Nothing else can offer one: `capture-pane`
                        # reads the grid, so a box showing a shell that has just
                        # printed a build log had no way at all to look back at
                        # it.
                        iframe_wheel!(f, b)
                    end
                    i = j + 1
                    continue
                end
            end
        end
        push!(out, bytes[i]); i += 1
    end
    out
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
    iframe_sync!(f, box...)
end

"""
    iframe_input!(f, bytes, origin, box; oncommand) -> :ok | :pop

Bytes as typed, straight through to the child.

No key is named, and the only sequence read on the way is a mouse report, whose
coordinates have to be moved into the child's box - see [`retarget_mouse`](@ref).
So this is the same amount of code whether the child is a shell, `vi` or
something not yet written.

The prefix is the one byte held back rather than forwarded, and it is tracked
across bursts: it can arrive alone, or ahead of its key in the same read.

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
                       box::NTuple{2,Int}; oncommand = nothing)
    f.client === nothing && return :pop
    # A key that finds the client dead is the first the host has heard of it,
    # when no wake said so: it is spent on saying the session ended, as a
    # sync would have, and the next one leaves - rather than going to a
    # client that cannot send it, forever.
    f.client.dead && (iframe_sync!(f, box...); return :ok)
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
            act = typed_input!(f, bytes[i:stop-k], origin, box; oncommand)
            act === :pop && return :pop
            j === nothing && break
            f.pasting = true
            f.brackets = f.client === nothing ? nothing : mux_brackets(f.client)
            f.brackets === true && append!(f.paste, PASTE_START)
            i = last(j) + 1
        end
    end
    :ok
end

"""What was typed, as opposed to pasted: mouse reports moved, the prefix held."""
function typed_input!(f::IFrame, bytes::Vector{UInt8}, origin::NTuple{2,Int},
                      box::NTuple{2,Int}; oncommand = nothing)
    f.client === nothing && return :pop
    was = f.scroll
    bytes = retarget_mouse(f, bytes, origin, box)
    # A scroll is only a different window on the same pane, so nothing wakes to
    # say it happened: the re-read has to be asked for here.
    f.scroll == was || iframe_sync!(f, box...)
    out = UInt8[]
    flush!() = begin
        isempty(out) && return
        live!(f, box)
        mux_keys(f.client, out)
        empty!(out)
    end
    for b in bytes
        if f.pending
            f.pending = false
            # Anything typed before the prefix goes first: the child should see
            # the order it was typed in, whatever the prefix then does.
            flush!()
            act = iframe_command!(f, b, box; oncommand)
            act === :pop && return :pop
            act === :literal && push!(out, IFRAME_PREFIX)
        elseif b == IFRAME_PREFIX
            f.pending = true
        else
            push!(out, b)
        end
    end
    flush!()
    :ok
end

"""
    iframe_close!(f)

Let go of the child. The session keeps running - that is what a session is for;
[`mux_kill`](@ref) is what ends one.
"""
iframe_close!(f::IFrame) = (f.client === nothing || mux_close(f.client); nothing)
