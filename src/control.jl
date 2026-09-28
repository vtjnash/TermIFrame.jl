# --- control mode -----------------------------------------------------------
#
# One `tmux -C attach` per session, over a pipe pair, is the whole transport.
# A command goes in as a line; its reply comes back framed between `%begin` and
# `%end` carrying the same id, or `%error` when it failed. Screen activity
# arrives unasked as `%output`, which is the signal to redraw.
#
# The alternative, a `tmux` process per keystroke and per frame, costs a fork
# each time (~5ms against ~1ms here) and has no way to be told that something
# changed; it can only ask.
#
# The line parser is split from the process on purpose. `mux_feed!` is a pure
# function of one line and the state before it, so the protocol is tested from
# a vector of strings and needs no tmux at all.

"""Parser state: whether a reply block is open, and what has arrived in it."""
mutable struct MuxProto
    inblock::Bool
    err::Bool
    lines::Vector{String}
end
MuxProto() = MuxProto(false, false, String[])

"""
    mux_feed!(p, line) -> (kind, a, b)

One protocol line. `kind` is

  * `:reply`  — a block closed; `a` is whether it succeeded, `b` its lines
  * `:output` — `a` is the pane id, `b` the decoded bytes
  * `:notice` — any other `%` notification; `a` is its name, `b` the rest
  * `:more`   — a line inside an open block, kept for the reply

A line inside a block is *not* a notification even when it starts with `%`: a
`capture-pane` of a screen with a percent sign on it would otherwise be read as
protocol. Only `%end` and `%error` close a block.
"""
function mux_feed!(p::MuxProto, line::AbstractString)
    if p.inblock
        if startswith(line, "%end ") || startswith(line, "%error ")
            p.inblock = false
            out = (:reply, !startswith(line, "%error "), copy(p.lines))
            empty!(p.lines)
            return out
        end
        push!(p.lines, String(line))
        return (:more, nothing, nothing)
    end
    if startswith(line, "%begin ")
        p.inblock = true
        empty!(p.lines)
        return (:more, nothing, nothing)
    end
    if startswith(line, "%output ")
        rest = SubString(line, 9)
        sp = findfirst(' ', rest)
        sp === nothing && return (:output, String(rest), "")
        return (:output, String(SubString(rest, 1, sp - 1)),
                mux_unescape(SubString(rest, sp + 1)))
    end
    if startswith(line, "%")
        sp = findfirst(' ', line)
        sp === nothing && return (:notice, String(line)[2:end], "")
        return (:notice, String(SubString(line, 2, sp - 1)), String(SubString(line, sp + 1)))
    end
    (:more, nothing, nothing)          # a stray line outside any block
end

"""
    passthrough(bytes) -> Vector{String}
    passthrough(carry, bytes) -> Vector{String}

What the child wrote that the screen cannot carry, to be sent on unchanged.

`capture-pane` reads the *grid*, and a grid is made of cells. A sequence that
paints no cell is not in it and never can be: the clipboard (OSC 52) is the one
that matters, because a program several terminals down that copies something has
no other way to reach the terminal a person is looking at. It arrives in
`%output` all the same - tmux passes it to a control-mode client whatever
`set-clipboard` is set to, which was measured rather than assumed - so the whole
of the fix is to notice it there and print it.

Only OSC 52, and deliberately so. `%output` is the child's entire byte stream,
and echoing any of the rest of it would be writing over a screen the host lays
out itself - cursor moves, colours and clears would land wherever the child
thought it was. A title or a bell would be defensible additions; anything that
draws is not.

**A sequence is not one `%output` line.** tmux cuts the stream into lines of
a few kilobytes at whatever byte it reaches, and a clipboard is base64 of
whatever was copied - a few paragraphs is past the first cut. So `carry` is
the unfinished tail of the last line, and the next line is read as its
continuation; a sequence is relayed once its terminator has arrived, and never
half-written. The one-argument form is a fresh carry, which is what the tests
want and what a single line gets. The carry is not bounded: a child that
stops mid-sequence stops, and what it wrote is all there is to hold.

Returns the sequences found, in order, with their terminators intact.
"""
passthrough(bytes::AbstractString) = passthrough(Ref(""), bytes)

const OSC52 = "\e]52;"

function passthrough(carry::Ref{String}, bytes::AbstractString)
    s = isempty(carry[]) ? String(bytes) : carry[] * bytes
    carry[] = ""
    isempty(s) && return String[]
    out = String[]
    i = firstindex(s)
    n = lastindex(s)
    while true
        j = findnext(OSC52, s, i)
        if j === nothing
            # The line may end inside the introducer itself: `\e]5` and then
            # `2;...` on the next one. Keep what could still become it - the
            # longest tail that is a prefix of it, as bytes, since the pane's
            # stream owes nobody valid UTF-8.
            for t in (ncodeunits(OSC52) - 1):-1:1
                ncodeunits(s) - t + 1 >= i || continue
                if endswith(s, SubString(OSC52, 1, t))
                    carry[] = OSC52[1:t]
                    break
                end
            end
            break
        end
        k = first(j)
        # OSC ends at BEL or at ST (ESC backslash), whichever comes first.
        b = findnext('\a', s, k)
        st = findnext("\e\\", s, k)
        stop = b === nothing ? (st === nothing ? nothing : last(st)) :
               st === nothing ? b : min(b, last(st))
        if stop === nothing
            # Truncated: the rest arrives on a later line, or never does.
            carry[] = String(SubString(s, k))
            break
        end
        push!(out, String(SubString(s, k, stop)))
        i = nextind(s, stop)
        i > n && break
    end
    out
end

"""
    mux_unescape(s) -> String

Undo the escaping tmux applies to `%output` data.

Only bytes below 0x20 and the backslash itself are escaped, as three octal
digits: a tab arrives as `\\011` and a backslash as `\\134`. Everything from
0x20 up passes through raw - DEL and UTF-8 continuation bytes included - so
this works on bytes rather than characters and leaves anything it does not
recognise exactly as it found it.
"""
function mux_unescape(s::AbstractString)
    occursin('\\', s) || return String(s)
    b = codeunits(s)
    out = IOBuffer()
    i = 1
    @inbounds while i <= length(b)
        c = b[i]
        if c == UInt8('\\') && i + 3 <= length(b) &&
           all(d -> UInt8('0') <= d <= UInt8('7'), (b[i+1], b[i+2], b[i+3]))
            write(out, UInt8((b[i+1] - 0x30) << 6 | (b[i+2] - 0x30) << 3 | (b[i+3] - 0x30)))
            i += 4
        else
            write(out, c)
            i += 1
        end
    end
    String(take!(out))
end

"""An attached control-mode client.

What the reader hears is kept here for the host to read, rather than handed to
functions the host passed in: a callback is a field of type `Any` and a dynamic
call on every `%output`, and all any host did with one was raise a wake.

  * `wake`      an `Event` that resets as it is taken, notified on each
                `%output` line, each notice below and once as the reader stops.
                [`mux_wait`](@ref) is the way to wait on it. A level and not a
                queue: a burst of output is one wake to whoever is waiting, and
                the reader never waits on the host to take it.
  * `relay`     what the child wrote that the screen cannot carry, not yet
                taken - see [`passthrough`](@ref) and [`mux_relay!`](@ref).
  * `sessions`  `%sessions-changed` has come since the host last lowered it.
  * `subs`      each subscription's latest value, by name (`refresh-client -B`).
  * `outputs`   how many `%output` lines have arrived, ever.
  * `bells`     the command pipe's bell subscription took
                ([`mux_pipe_open`](@ref)); a change in who rang is then a wake.

`lock` is held by [`mux_ask`](@ref) from the write to the reply. Replies are
matched by position, so two tasks asking one client at once could each take
the other's answer; a client with one caller never waits on it. The reader
takes no lock: it only puts replies on `replies`, and tmux sends no
notification inside a reply.
"""
mutable struct MuxClient
    name::String
    proc::Base.Process
    proto::MuxProto
    replies::Channel{Any}
    lock::ReentrantLock
    wake::Base.Event
    relay::Vector{String}
    carry::Dict{String,Base.RefValue{String}}
    sessions::Bool
    subs::Dict{String,String}
    outputs::Int
    bells::Bool
    reader::Union{Task,Nothing}
    dead::Bool
    why::String                 # what killed it, for the status line: a
                                # client that is dead with no reason on it
                                # was read as the server having gone away,
                                # when it was a reply five seconds late
end

"Mark the client dead, with the first reason kept, and wake whoever waits on it."
function mux_dead!(c::MuxClient, why::AbstractString)
    c.dead || (c.why = String(why))
    c.dead = true
    notify(c.wake)
    nothing
end

"""
    mux_open(name; flags = "") -> MuxClient | Nothing

Attach to `name` in control mode.

The session must already exist; starting one is [`mux_start`](@ref)'s job, and
keeping the two separate is what lets a session outlive every client that has
looked at it. `flags` are `attach -f`'s - the command pipe is
`no-output,ignore-size`.

The reader notifies `wake` for each `%output` line, and once more when it
stops - the session ended, the server went away, or the client was closed. The
last is not the first with nothing to say: a child that writes its last words
and then takes a while to exit ends the session after the last `%output`, and
a host that redraws on output alone never looks again. It went on showing the
child's final screen, with every key sent to a client that was already dead.
"""
function mux_open(name::AbstractString; flags::AbstractString = "")
    cmd = isempty(flags) ? mux_cmd("-C", "attach", "-t=" * String(name)) :
                           mux_cmd("-C", "attach", "-f", String(flags), "-t=" * String(name))
    cmd === nothing && return nothing
    mux_alive(name) || return nothing
    proc = try
        open(cmd, "r+")
    catch
        return nothing
    end
    c = MuxClient(String(name), proc, MuxProto(), Channel{Any}(Inf), ReentrantLock(),
                  Base.Event(true), String[], Dict{String,Base.RefValue{String}}(),
                  false, Dict{String,String}(), 0, false, nothing, false, "")
    c.reader = @async mux_read(c)
    mux_sync!(c) || (mux_close(c); return nothing)
    c
end

"""The reader: every line the client says, until it stops.

Never waits on the host. It puts replies on a channel of unbounded size, keeps
what it heard on the client, and notifies an `Event`, none of which blocks.
"""
function mux_read(c::MuxClient)
    try
        for line in eachline(c.proc.out)
            kind, a, b = mux_feed!(c.proto, line)
            if kind === :reply
                put!(c.replies, (a, b))
            elseif kind === :output
                c.outputs += 1
                # What a redraw cannot carry - the clipboard and nothing else,
                # for the reasons in `passthrough` - kept for the host to take
                # on its own task, between frames. One carry per pane: an
                # `%output` line is a cut of one pane's stream, and a clipboard
                # longer than the cut finishes on a later line.
                append!(c.relay, passthrough(get!(() -> Ref(""), c.carry, a), b))
                notify(c.wake)
            elseif kind === :notice
                if a == "exit"
                    mux_dead!(c, isempty(b) ? "the server said exit" :
                                 string("the server said exit: ", b))
                    break
                elseif a == "sessions-changed"
                    c.sessions = true
                    notify(c.wake)
                elseif a == "subscription-changed"
                    # `name $s @w w %p : value` - the value is everything after
                    # the first ` : `, and may itself hold one.
                    sp = findfirst(' ', b)
                    at = findfirst(" : ", b)
                    if sp !== nothing && at !== nothing
                        c.subs[b[1:prevind(b, sp)]] = b[last(at)+1:end]
                        notify(c.wake)
                    end
                end
            end
        end
        mux_dead!(c, "the control client closed its end")
    catch e
        mux_dead!(c, string("reading the control client: ",
                            first(sprint(showerror, e), 80)))
    finally
        isopen(c.replies) && put!(c.replies, (false, ["client closed"]))
        notify(c.wake)
    end
end

"""
    mux_wait(c) -> Bool

Wait until the client has something to say - output, a notice, or that it
ended - and answer whether it is still alive. A host's loop is

    @async while mux_wait(c); redraw(); end; redraw()

with the last one for the end, which the host has to see as much as any output.
Returns at once, `false`, for a client already dead.
"""
function mux_wait(c::MuxClient)
    c.dead && return false
    wait(c.wake)
    !c.dead
end

"""
    mux_relay!(c) -> Vector{String}

The sequences the child wrote that the screen cannot carry, taken: the host
prints them to its own terminal, which is the next one up. See
[`passthrough`](@ref).
"""
function mux_relay!(c::MuxClient)
    isempty(c.relay) && return String[]
    out, c.relay = c.relay, String[]
    out
end

"""
    mux_sync!(c; timeout) -> Bool

Line the reply stream up with the commands, and say whether it worked.

Attaching is itself a command as far as the server is concerned: it answers
with a `%begin`/`%end` block of its own before anything has been asked of it.
That block sits in the queue and every later reply is then one behind - the
first `capture-pane` comes back empty and the *next* command returns the
screen, which looks like a capture that failed rather than a stream that has
slipped.

Draining a fixed number of blocks would only work until a version emitted a
different number of them. A token nothing else could produce does not care:
throw replies away until the one that echoes it comes back.
"""
function mux_sync!(c::MuxClient; timeout::Real = 5.0)
    @lock c.lock mux_sync_locked!(c, timeout)
end

function mux_sync_locked!(c::MuxClient, timeout::Real)
    tok = string("iframe-sync-", string(rand(UInt32); base = 16))
    try
        write(c.proc.in, "display-message -p ", tok, "\n")
        flush(c.proc.in)
    catch
        mux_dead!(c, "could not write to the control client")
        return false
    end
    deadline = time() + timeout
    while true
        left = deadline - time()
        left <= 0 && break
        late = Timer(_ -> (isopen(c.replies) && put!(c.replies, :timeout)), left)
        r = try
            take!(c.replies)
        finally
            close(late)
        end
        r === :timeout && break
        if r isa Tuple && length(r[2]) == 1 && strip(r[2][1]) == tok
            return true
        end
    end
    mux_dead!(c, "the attach did not answer in $(timeout)s")
    false
end

"""
    mux_ask(c, cmd; timeout) -> (ok, lines)

Send one command and wait for its reply.

Replies come back in the order the commands went out, so they are matched by
position rather than by parsing the id out of `%begin`. A timeout therefore
cannot be recovered from - the next reply would answer the wrong question - so
it kills the client instead of desynchronising it. For the same reason the
ask holds the client's lock from the write to the reply: two tasks asking at
once would otherwise each take the other's answer.
"""
function mux_ask(c::MuxClient, cmd::AbstractString; timeout::Real = 5.0)
    @lock c.lock mux_ask_locked(c, cmd, timeout)
end

function mux_ask_locked(c::MuxClient, cmd::AbstractString, timeout::Real)
    c.dead && return (false, ["client closed"])
    try
        write(c.proc.in, cmd, '\n')
        flush(c.proc.in)
    catch
        mux_dead!(c, "could not write to the control client")
        return (false, ["client closed"])
    end
    late = Timer(_ -> (isopen(c.replies) && put!(c.replies, :timeout)), timeout)
    try
        r = take!(c.replies)
        if r === :timeout
            mux_dead!(c, string("no reply in $(timeout)s to ", first(split(cmd, ' '))))
            return (false, ["timed out"])
        end
        return r
    finally
        close(late)
    end
end

"""
    mux_capture(c; escapes, scroll, rows) -> Vector{String}

The rendered screen of the session's active pane.

`-e` keeps the SGR escapes, and from tmux 3.4 the OSC 8 hyperlinks with them;
3.1c returns the link text with the URL dropped.

The target is `=name:` and not `=name`: the `=` exact form takes a session on
`has-session`, but `capture-pane` wants a pane, and `=name` there is read as a
pane called `name` and not found.

It is also written unquoted. Control mode does its own quote handling, and
`-t='=name:'` comes back *successful and empty* while `-t '=name:'` fails
outright looking for a session called `=name`. [`mux_name`](@ref) has already
rewritten the characters tmux would object to, so there is nothing left here
that would need quoting.
"""
function mux_capture(c::MuxClient; escapes::Bool = true,
                     scroll::Int = 0, rows::Int = 0)
    # `-S`/`-E` count lines from the top of the visible screen: 0 is the first
    # row of it and negative numbers are history. So a window of `rows` lines
    # scrolled up by `scroll` is exactly `-scroll` to `rows - 1 - scroll`, and
    # the end going negative too is not a special case - it is a window entirely
    # in the history. Omitted at rest, so the common call is the one it was.
    win = (scroll > 0 && rows > 0) ?
          string(" -S -", scroll, " -E ", rows - 1 - scroll) : ""
    ok, lines = mux_ask(c, string("capture-pane -p", escapes ? " -e" : "", win,
                                  " -t =", c.name, ":"))
    ok ? lines : String[]
end

"""What tmux's copy mode is showing, read from its formats because it cannot
be read any other way: `capture-pane` reads the pane's own grid, never the
mode's screen.

`scroll` is how far back the mode's view is, and the same thing
`capture-pane -S` is told for a window that far back. `cursor` is a cell of
that view, 0-based. `sel` is the selection's start and end as tmux keeps
them - `(sx, sy, ex, ey)`, the end being where the cursor is dragging it -
in lines of the whole grid, the oldest line of history 0, so a view row `r`
is line `history - scroll + r`. `nothing` while there is none to draw, which
includes one begun and still empty. `rect` and `vi` are the two things that
change which cells it covers ([`copy_selected`](@ref)).
"""
struct CopyMode
    scroll::Int
    cursor::Tuple{Int,Int}
    sel::Union{Nothing,NTuple{4,Int}}
    rect::Bool
    vi::Bool
end

"""
    mux_pane_state(c) -> (x, y, showing, mouse, history, alt, copy, dead)

What the pane knows that its screen does not say.

Both in one round trip, because both are wanted on every redraw.

`(x, y)` are zero-based, as tmux counts them. The cursor has to be asked for
because `capture-pane` returns the grid and nothing else, and the real cursor is
hidden for the whole of a host's run.

`mouse` is whether the *child* turned mouse reporting on. It matters because a
mouse report forwarded to a program that never asked for one is printed as the
control characters it is.

`history` and `alt` are what the pane's own scrollback is worth. How far back it
goes bounds the scroll; whether the child is on the alternate screen decides
whether there is anything back there worth showing - a full-screen program's
history is the wreckage of its redraws, which is why terminals stop offering
scrollback while one is up.

`copy` is the pane's copy mode, a [`CopyMode`](@ref), or `nothing` when it
is not in one - including when it is in some other mode, which draws nothing
this can read.

`dead` is the child's exit status when it has exited and the server kept the
pane (`remain-on-exit`, which [`mux_start`](@ref) sets for a failure), and
`nothing` while it runs.

The format is quoted and the target is not, which is the opposite way round
from everywhere else and is not a preference: `#` starts a comment in tmux's
command syntax, so an unquoted format is discarded and the default message
comes back instead - successfully, and about the session rather than the pane.
A quoted *target* meanwhile succeeds and matches nothing.
"""
function mux_pane_state(c::MuxClient)
    ok, lines = mux_ask(c, string("display-message -p -t =", c.name,
        ": '#{cursor_x},#{cursor_y},#{cursor_flag},#{mouse_any_flag}," *
        "#{history_size},#{alternate_on}," *
        "#{pane_mode},#{scroll_position},#{copy_cursor_x},#{copy_cursor_y}," *
        "#{selection_present},#{selection_start_x},#{selection_start_y}," *
        "#{selection_end_x},#{selection_end_y},#{rectangle_toggle},#{mode-keys}," *
        "#{pane_dead},#{pane_dead_status}'"))
    none = (0, 0, false, false, 0, false, nothing, nothing)
    (ok && !isempty(lines)) || return none
    f = split(strip(lines[1]), ',')
    length(f) == 19 || return none
    num(i) = something(tryparse(Int, f[i]), 0)
    # `view-mode` is copy mode too - what `run-shell` output is shown in.
    copy = f[7] in ("copy-mode", "view-mode") ?
        CopyMode(num(8), (num(9), num(10)),
                 f[11] == "1" ? (num(12), num(13), num(14), num(15)) : nothing,
                 f[16] == "1", f[17] == "vi") : nothing
    # A child killed by a signal has no status; it failed all the same.
    dead = f[18] == "1" ? something(tryparse(Int, f[19]), -1) : nothing
    (num(1), num(2), f[3] == "1", f[4] == "1", num(5), f[6] == "1", copy, dead)
end

"""
    copy_selected(m, x, y) -> Bool

Whether the cell at column `x` of grid line `y` is inside the selection
[`CopyMode`](@ref) `m` shows. tmux's own `screen_check_selection`, the rule
its copy mode is drawn by and copies by: emacs keys drop the bottom-right
cell and vi keys keep it, whichever way the drag went, and a rectangle takes
the columns between the two ends on every line between them.
"""
function copy_selected(m::CopyMode, x::Int, y::Int)
    m.sel === nothing && return false
    sx, sy, ex, ey = m.sel
    if m.rect
        min(sy, ey) <= y <= max(sy, ey) || return false
        return min(sx, ex) <= x <= max(sx, ex)
    end
    if sy < ey
        (sy <= y <= ey) || return false
        y == sy && x < sx && return false
        xx = m.vi ? ex : max(ex - 1, 0)
        return !(y == ey && x > xx)
    elseif sy > ey
        (ey <= y <= sy) || return false
        y == ey && x < ex && return false
        return !(y == sy && (sx == 0 || x > (m.vi ? sx : sx - 1)))
    else
        y == sy || return false
        if ex < sx
            return ex <= x <= (m.vi ? sx : sx - 1)
        else
            return sx <= x <= (m.vi ? ex : max(ex - 1, 0))
        end
    end
end

"""
    mux_resize(c, w, h) -> Bool

Size the session to `w` by `h`.

A pane is a whole session because `new-window` has no `-x`/`-y` in any version,
so this is how an iframe gives its child the size of the box it is drawn in.
"""
mux_resize(c::MuxClient, w::Integer, h::Integer) =
    first(mux_ask(c, string("refresh-client -C ", w, ",", h)))

"""
    mux_keys(c, bytes) -> Bool

Send bytes to the pane exactly as typed.

`send-keys -H` takes hex, which is the point: no key name is looked up and no
sequence is interpreted, so an arrow, a paste and a mouse report all go through
as themselves.
"""
function mux_keys(c::MuxClient, bytes::AbstractVector{UInt8})
    isempty(bytes) && return true
    hex = join((string(b; base = 16, pad = 2) for b in bytes), ' ')
    first(mux_ask(c, string("send-keys -H -t =", c.name, ": ", hex)))
end
mux_keys(c::MuxClient, s::AbstractString) = mux_keys(c, collect(codeunits(s)))

"""
    mux_brackets(c) -> Bool | Nothing

Whether the child has bracketed paste on, or `nothing` where the server cannot
say.

`#{bracket_paste_flag}` is tmux 3.7's, and it is the server that expands it -
whichever binary started the server, which may be the user's own long-running
one - so an older server answers with nothing at all. Asked rather than
followed from the child's output: `?2004h` in `%output` is seen only while a
client is attached, and a child that set it before this attach (an agent
reopened) never says it again.
"""
function mux_brackets(c::MuxClient)
    ok, lines = mux_ask(c, string("display-message -p -t =", c.name,
                                  ": '#{bracket_paste_flag}'"))
    (ok && !isempty(lines)) || return nothing
    v = strip(lines[1])
    v == "1" ? true : v == "0" ? false : nothing
end

"""
    mux_paste(c, bytes) -> Bool

Paste `bytes` into the pane, bracketed only if the child asked for it, in one
piece - for a server that cannot say whether it did ([`mux_brackets`](@ref)).

`paste-buffer -p` asks the pane itself: the markers go round the text where
the child set `?2004` and nowhere else.
`send-keys -H` would send markers as the bytes they are, into a shell that
never asked for them. `-r` keeps the text as the terminal sent it, since tmux
would otherwise turn every newline into a carriage return.

The text goes into a buffer of this client's own in pieces, each a
double-quoted string with every byte past the plainest written in octal - the
control-mode command line is parsed, so a newline would end it and `\$`, `~`
and `#` mean something. A NUL cannot be written at all (it ends the string
tmux builds), so it is dropped; `-d` deletes the buffer once it is pasted.
"""
function mux_paste(c::MuxClient, bytes::AbstractVector{UInt8})
    bytes = filter(!iszero, bytes)
    isempty(bytes) && return true
    buf = string("paste-", getpid())       # this process's, and plain to write
    for (i, part) in enumerate(Iterators.partition(bytes, 4096))
        q = sprint() do io
            print(io, '"')
            for b in part
                if UInt8('a') <= b <= UInt8('z') || UInt8('A') <= b <= UInt8('Z') ||
                   UInt8('0') <= b <= UInt8('9') || b == UInt8(' ')
                    print(io, Char(b))
                else
                    print(io, '\\', string(b; base = 8, pad = 3))
                end
            end
            print(io, '"')
        end
        first(mux_ask(c, string("set-buffer ", i == 1 ? "" : "-a ", "-b ", buf, " ", q))) ||
            return false
    end
    first(mux_ask(c, string("paste-buffer -p -r -d -b ", buf, " -t =", c.name, ":")))
end

"""
    mux_close(c)

Let go of the client. The session it was attached to keeps running, which is the
whole point of there being a session.
"""
function mux_close(c::MuxClient)
    mux_dead!(c, "closed")
    try; close(c.proc.in); catch; end
    try; kill(c.proc); catch; end
    nothing
end

# --- the command pipe --------------------------------------------------------
#
# Every `mux(...)` is a `tmux` process otherwise, ~3 ms each (3.2 ms measured),
# where the same command down a control client is a few hundredths of one. A
# control client has to be attached to stay open - with any other command
# `tmux -C` runs it and exits - and attaching to a session of ours counts as
# looking at it and clears its bell. So the pipe is parked on a session
# of its own, named outside the prefix, where a session beside it was left
# `attached=0` with its bell standing (measured on 3.5a).
#
# One per process, which for a host is one per browser: a global. Opened for
# one prefix, whose bells it hears; a process with sessions under two prefixes
# has not needed a pipe for each yet. Separate from any iframe's client - a pane's client ends with its
# session, and one client for both would `switch-client` from session to
# session, clearing each bell it passed.

"""The command pipe while one is open: see [`mux_pipe_open`](@ref)."""
const MUX_PIPE = Ref{Union{Nothing,MuxClient}}(nothing)

"""
    mux_pipe() -> MuxClient | Nothing

The command pipe, if one is open and alive. What [`mux`](@ref) sends down.
"""
function mux_pipe()
    c = MUX_PIPE[]
    (c === nothing || c.dead) ? nothing : c
end

"""The session a process parks its pipe on: `_<prefix>-ctl-<pid>`, outside
the prefix, so that [`mux_sessions`](@ref) and [`mux_list`](@ref) do not count
it. Not hidden: `tmux ls` shows it like any other."""
pipe_session(prefix::AbstractString, pid::Integer = getpid()) =
    string("_", prefix, "-ctl-", pid)

"""The subscription the pipe asks for: which sessions under `prefix` have their bell
standing, as their ids. tmux checks it once a second and says
`%subscription-changed` when the answer differs, which is how a host hears a
bell without listing the sessions on a clock. The `S:` loop is over every
session on the server, where a subscription is otherwise about the session the
client is attached to - the pipe's own."""
bell_format(prefix::AbstractString) =
    string("#{S:#{?#{&&:#{m:", prefix, "-*,#{session_name}},#{window_bell_flag}},#{session_id} ,}}")

"""The name the bell subscription is kept under in the pipe's `subs`."""
const MUX_BELLS = "bells"

"""
    mux_pipe_open(prefix) -> MuxClient | Nothing

Open the command pipe for the sessions under `prefix`, or answer the one
already open - which is one per process, whatever prefix it was opened for.

A server is started by the `new-session` under it if there is none, so a host
opens this only once there is a session of its own to talk about - found at
launch, or just started - and closes it when the last one ends
([`mux_pipe_close`](@ref)); a pipe with nothing left to ask about would keep a
server up for itself.

The pipe's session runs `cat`, which waits on a terminal nobody types into, and
its client is `no-output,ignore-size`: nothing it shows is read, and its size is
nobody's business. It ends with its client: `destroy-unattached` is set once the
client is on it - set on a session with nobody attached it ends it on the spot
(measured on 3.5a) - so a host that dies closes the client's stdin, the client
exits and the session goes. A host that died between the two leaves one behind,
and the next to open a pipe ends it, since it would keep the server up.

The bell subscription ([`bell_format`](@ref)), for `prefix`, is asked for here; `bells` on the
client says whether it took, which a server before 3.2 would refuse. The
terminal's background, if the host has heard it, goes on every pane under
`prefix` ([`mux_bg!`](@ref)). Answers
`nothing` where there is no tmux or the attach failed, and [`mux`](@ref) goes on
spawning.
"""
function mux_pipe_open(prefix::AbstractString)
    c = mux_pipe()
    c === nothing || return c
    MUX_PIPE[] = nothing
    mux_bin() === nothing && return nothing
    mux_pipe_sweep(prefix)
    name = pipe_session(prefix)
    first(mux_spawn("new-session", "-d", "-s", name, "cat")) || return nothing
    c = mux_open(name; flags = "no-output,ignore-size")
    c === nothing && (mux_spawn("kill-session", "-t=" * name); return nothing)
    mux_ask(c, mux_line(["set", "-t", name, "destroy-unattached", "on"]))
    c.bells = first(mux_ask(c, mux_line(["refresh-client", "-B",
                                         string(MUX_BELLS, "::", bell_format(prefix))])))
    MUX_PIPE[] = c
    MUX_OLDER[] = mux_older(c)
    # Panes that were running before there was a pipe to seed them down.
    mux_seed_all(prefix)
    c
end

"""The server's version and this binary's, when the server is the older: `("3.4",
"3.5a")`, else `("", "")`. Set when the pipe opens and cleared when it closes,
since the server can be a different one each time.

A server already running on the socket is the one every binary talks to, and
its version, not ours, decides what a command does - so one older than ours may
be missing what this package counts on, whichever thing that turns out to be,
and a host has something to tell its user. A version that does not read as
`<major>.<minor>[letter]` (`master`, say) is not called older."""
const MUX_OLDER = Ref(("", ""))

"""Ask the server over `c` for its version and this binary for its own, and
answer them as [`MUX_OLDER`](@ref) holds them."""
function mux_older(c::MuxClient)
    ok, lines = mux_ask(c, mux_line(["display", "-p", "#{version}"]))
    server = ok && !isempty(lines) ? strip(first(lines)) : ""
    ok, out = mux_spawn("-V")
    ours = ok ? strip(replace(out, r"^tmux " => "")) : ""
    a, b = mux_version(server), mux_version(ours)
    a === nothing || b === nothing || a >= b ? ("", "") : (String(server), String(ours))
end

"""A tmux version as something to compare: `3.5a` is `(3, 5, 'a')`, and `3.5`
`(3, 5, ' ')`, before it; `next-3.6` is 3.6. `nothing` for anything else."""
function mux_version(v::AbstractString)
    m = match(r"(\d+)\.(\d+)([a-z]?)", v)
    m === nothing && return nothing
    (parse(Int, m[1]), parse(Int, m[2]), isempty(m[3]) ? ' ' : m[3][1])
end

"""End the sessions of pipes whose process is gone: a host that died
after starting one and before its client was on it. Not our own, and not one
whose name does not end in a pid."""
function mux_pipe_sweep(prefix::AbstractString)
    ok, out = mux_spawn("list-sessions", "-F", "#{session_name}")
    ok || return
    p = string("_", prefix, "-ctl-")
    for n in split(out, '\n'; keepempty = false)
        startswith(n, p) || continue
        pid = tryparse(Int, n[ncodeunits(p)+1:end])
        (pid === nothing || pid == getpid() || pid_alive(pid)) && continue
        mux_spawn("kill-session", "-t=" * String(n))
    end
end

"Whether a process of this id is running: signal 0, which only asks."
pid_alive(pid::Integer) =
    ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) != Base.UV_ESRCH

"""
    mux_pipe_close()

Close the command pipe, if one is open, and end its session: when the
host's last session has ended, and when the host exits. Commands are spawned
again from here on. Closing the client ends the session by itself
(`destroy-unattached`); the `kill-session` after it is for a server on which
that did not take.
"""
function mux_pipe_close()
    c = MUX_PIPE[]
    MUX_PIPE[] = nothing
    MUX_OLDER[] = ("", "")
    c === nothing && return nothing
    mux_close(c)
    mux_spawn("kill-session", "-t=" * c.name)
    nothing
end
