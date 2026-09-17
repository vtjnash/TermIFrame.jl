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

Returns the sequences found, in order, with their terminators intact.
"""
function passthrough(bytes::AbstractString)
    isempty(bytes) && return String[]
    out = String[]
    i = firstindex(bytes)
    n = lastindex(bytes)
    while true
        j = findnext("\e]52;", bytes, i)
        j === nothing && break
        k = first(j)
        # OSC ends at BEL or at ST (ESC backslash), whichever comes first.
        b = findnext('\a', bytes, k)
        st = findnext("\e\\", bytes, k)
        stop = b === nothing ? (st === nothing ? nothing : last(st)) :
               st === nothing ? b : min(b, last(st))
        stop === nothing && break        # truncated; the rest may arrive next time
        push!(out, String(SubString(bytes, k, stop)))
        i = nextind(bytes, stop)
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

`onoutput` is called with the pane id and the bytes the child wrote whenever
that pane changes. It runs on the reader task, so it should do the least
possible: wake whatever draws, and pass on anything the child said that the
*screen* cannot carry - see [`passthrough`](@ref).
"""
mutable struct MuxClient
    name::String
    proc::Base.Process
    proto::MuxProto
    replies::Channel{Any}
    onoutput::Any
    reader::Union{Task,Nothing}
    dead::Bool
    why::String                 # what killed it, for the status line: a
                                # client that is dead with no reason on it
                                # was read as the server having gone away,
                                # when it was a reply five seconds late
end

"Mark the client dead, with the first reason kept."
function mux_dead!(c::MuxClient, why::AbstractString)
    c.dead || (c.why = String(why))
    c.dead = true
    nothing
end

"""
    mux_open(name; onoutput) -> MuxClient | Nothing

Attach to `name` in control mode.

The session must already exist; starting one is [`mux_start`](@ref)'s job, and
keeping the two separate is what lets a session outlive every client that has
looked at it.
"""
function mux_open(name::AbstractString; onoutput = nothing)
    cmd = mux_cmd("-C", "attach", "-t=" * String(name))
    cmd === nothing && return nothing
    mux_alive(name) || return nothing
    proc = try
        open(cmd, "r+")
    catch
        return nothing
    end
    c = MuxClient(String(name), proc, MuxProto(), Channel{Any}(Inf), onoutput, nothing,
                  false, "")
    c.reader = @async begin
        try
            for line in eachline(proc.out)
                kind, a, b = mux_feed!(c.proto, line)
                if kind === :reply
                    put!(c.replies, (a, b))
                elseif kind === :output
                    c.onoutput === nothing || c.onoutput(a, b)
                elseif kind === :notice && a == "exit"
                    mux_dead!(c, isempty(b) ? "the server said exit" :
                                 string("the server said exit: ", b))
                    break
                end
            end
            mux_dead!(c, "the control client closed its end")
        catch e
            mux_dead!(c, string("reading the control client: ",
                                first(sprint(showerror, e), 80)))
        finally
            isopen(c.replies) && put!(c.replies, (false, ["client closed"]))
        end
    end
    mux_sync!(c) || (mux_close(c); return nothing)
    c
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
it kills the client instead of desynchronising it.
"""
function mux_ask(c::MuxClient, cmd::AbstractString; timeout::Real = 5.0)
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

"""
    mux_pane_state(c) -> (x, y, showing, mouse, history, alt)

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

The format is quoted and the target is not, which is the opposite way round
from everywhere else and is not a preference: `#` starts a comment in tmux's
command syntax, so an unquoted format is discarded and the default message
comes back instead - successfully, and about the session rather than the pane.
A quoted *target* meanwhile succeeds and matches nothing.
"""
function mux_pane_state(c::MuxClient)
    ok, lines = mux_ask(c, string("display-message -p -t =", c.name,
        ": '#{cursor_x},#{cursor_y},#{cursor_flag},#{mouse_any_flag}," *
        "#{history_size},#{alternate_on}'"))
    none = (0, 0, false, false, 0, false)
    (ok && !isempty(lines)) || return none
    f = split(strip(lines[1]), ',')
    length(f) == 6 || return none
    (something(tryparse(Int, f[1]), 0), something(tryparse(Int, f[2]), 0),
     f[3] == "1", f[4] == "1", something(tryparse(Int, f[5]), 0), f[6] == "1")
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
