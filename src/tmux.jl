# Session bookkeeping: find the binary, name a session, start one, tag it, list
# them. All one-shot `tmux` commands; the long-lived client is `control.jl`.
#
# A multiplexer session is what makes an embedded program possible at all. It
# holds a program that outlives the view of it, it can be looked at again later,
# and - the part everything above depends on - its screen can be read back as
# text without the reader having to understand a single escape sequence.

"""The environment variable that names the multiplexer binary.

A host with a name of its own sets this once, so that the variable a user is
told to export is spelled after the program they are running.
"""
const MUX_ENV = Ref("TERMIFRAME_TMUX")

"""The binary `tmux_jll` ships, or `nothing` on a platform it has no build for.

A dependency rather than a line in a README, because a package whose whole
subject is running a program in a tmux session should not be the thing that
cannot find one - and, since [`mux_bin`](@ref) does not consult `PATH`, this is
what it normally runs. Windows is the platform with no build, and there this is
`nothing` - which is an answer the rest of this handles, the same as any other
machine with no tmux on it.
"""
bundled_tmux() = try
    tmux_jll.is_available() ? tmux_jll.tmux_path : nothing
catch
    nothing
end

"""
    mux_bin() -> String | Nothing

The multiplexer binary, or `nothing` when there is none.

`tmux_jll`'s, unless [`MUX_ENV`](@ref)'s variable names another - which is the
deliberate override, and how a particular build gets tested.

`PATH` is deliberately *not* consulted, and the reason is that consulting it
would buy nothing. A tmux binary holds no sessions: they live in a server
process addressed by a socket - `\$TMUX_TMPDIR/tmux-\$UID/default` by default - so
any binary that opens that socket sees the same sessions, and a person's own
`tmux ls` lists the ones started here whichever binary started them. The
protocol version has been 8 for the whole of tmux 3.x, so the bundled client and
an installed server talk to each other.

What following `PATH` *would* cost is knowing what we are talking to. The
commands here are version-sensitive in small ways - `capture-pane -e` keeps OSC 8
hyperlinks from 3.4 and drops the URL in 3.1c - and one known build is one set of
behaviours to reason about instead of whatever is installed.

One thing this does not pin, and cannot: the *server* is what renders
`capture-pane` and evaluates the formats, so where one is already running on that
socket its version governs no matter which binary connects to it.

This is the answer to "is there one, and which", for a caller that wants to say
so. What actually *runs* it is [`mux_cmd`](@ref), because for the bundled binary
a path on its own is not enough.
"""
function mux_bin()
    b = get(ENV, MUX_ENV[], "")
    isempty(b) || return isfile(b) ? b : nothing
    bundled_tmux()
end

"""
    no_mux() -> String

The status line for [`mux_bin`](@ref) answering `nothing`, saying where it did
look - which is not `PATH`. Exported so a host that guards its own keystroke
paths on `mux_bin()` says the same thing this does.
"""
no_mux() = isempty(get(ENV, MUX_ENV[], "")) ?
    "no tmux: tmux_jll has no build for this platform and \$$(MUX_ENV[]) is unset" :
    "no tmux: \$$(MUX_ENV[]) names no file"

"""
    mux_cmd(args...) -> Cmd | Nothing

The command that runs the multiplexer with `args` appended, or `nothing` when
there is none to run. The same two places as [`mux_bin`](@ref), in the same
order.

Built here rather than interpolated from a path at each call site, because for
the bundled binary a path is not enough: `tmux_jll` carries its own libraries
and terminfo in the environment of the `Cmd` it hands out, and the path alone
gets `libutf8proc.so.3: cannot open shared object file`.
"""
function mux_cmd(args::AbstractString...)
    a = collect(String, args)
    b = get(ENV, MUX_ENV[], "")
    isempty(b) || return isfile(b) ? `$b $a` : nothing
    bundled_tmux() === nothing ? nothing : `$(tmux_jll.tmux()) $a`
end

"""
    mux_name(prefix, parts...; kind = :shell) -> String

What to *call* a session, out of the parts that say which one it is: `prefix`
first, which is what a host lists its own by ([`mux_sessions`](@ref),
[`mux_list`](@ref)) - a session someone started by hand is not a host's to list
or to kill.

This is a label and not an identity: the things worth naming a session after -
the branch it is on, what was in view when it was opened - change under a
session that has not moved. What a session *is* lives in its options; see
[`mux_tag!`](@ref).

Empty parts are dropped, and `kind` is appended unless it is `:shell`, so a
shell and an agent in the same place are two different names.

tmux does not reject `.` or `:` in a session name, it silently rewrites them to
`_`, so `wl-Distributed.jl-198` is created and then cannot be found under the
name it was asked for. Doing the same substitution here means the name held on
this side is the name the server holds. `/` it leaves alone, which is what lets
a branch keep its owner prefix.
"""
function mux_name(prefix::AbstractString, parts::AbstractString...; kind::Symbol = :shell)
    clean(x) = replace(String(x), '.' => '_', ':' => '_')
    out = [String(prefix)]
    for p in parts
        isempty(p) || push!(out, clean(p))
    end
    kind === :shell || push!(out, String(kind))
    join(out, '-')
end


"""
    mux(args...) -> (ok, output)
    mux(cmds::Vector{Vector{String}}) -> (ok, output)

Run one multiplexer command, or several in order - stopping at the first that
fails - with the output of all of them.

Down the command pipe while one is open ([`mux_pipe_open`](@ref)), and as a
`tmux` process otherwise: a process is ~3 ms, the same command on the pipe
0.04 to 0.16 ms (3.5a). Which one ran is not the caller's concern; what each
needs quoting against is, and differs, so it is done here -
[`mux_line`](@ref) for the pipe and [`mux_spawn`](@ref) for a process.
A command with a newline in it cannot be written as a control line and is
spawned whatever is open.

Never throws: every caller is on a keystroke path where a missing binary or a
dead server has to become a status line, not a backtrace.
"""
mux(args::AbstractString...) = mux([String[String(a) for a in args]])

function mux(cmds::Vector{Vector{String}})
    c = mux_pipe()
    if c !== nothing && !any(cmd -> any(a -> occursin('\n', a) || occursin('\r', a), cmd), cmds)
        out = IOBuffer()
        for (i, cmd) in enumerate(cmds)
            ok, lines = mux_ask(c, mux_line(cmd))
            # A pipe that died under the ask is not an answer: the rest go as
            # processes. Everything sent this way is idempotent or says so -
            # a `new-session` that did get through is `duplicate session`.
            (!ok && c.dead) && return mux_spawn(cmds[i:end])
            for l in lines
                println(out, l)
            end
            ok || return (false, String(take!(out)))
        end
        return (true, String(take!(out)))
    end
    mux_spawn(cmds)
end

"""
    mux_spawn(args...) -> (ok, output)

Run one multiplexer command as a process of its own, whatever pipe is open.

For the commands that are about the client asking: `switch-client` moves the
client it came from, which down the pipe would be the pipe, and an attach is a
client of its own ([`mux_seen!`](@ref)).

Several commands are one process, joined by `;`. In an argument, a `;` at the
end is a separator too - `set @x 'y;'` sets `y`, measured on 3.5a - so one is
sent as `\\;`, which tmux reads as the character. The rule is the argument
list's: on a control line a quoted `'y;'` is `y;`, and that is `mux_line`'s.
"""
mux_spawn(args::AbstractString...) = mux_spawn([String[String(a) for a in args]])

function mux_spawn(cmds::Vector{Vector{String}})
    argv = String[]
    for cmd in cmds
        isempty(argv) || push!(argv, ";")
        for a in cmd
            push!(argv, endswith(a, ';') ? string(chop(a), "\\;") : a)
        end
    end
    cmd = mux_cmd(argv...)
    cmd === nothing && return (false, no_mux())
    try
        out = read(pipeline(cmd; stderr = devnull), String)
        (true, out)
    catch e
        (false, e isa ProcessFailedException ? "" : first(sprint(showerror, e), 80))
    end
end

"""
    mux_line(args) -> String

One command as a control-mode line: each argument as a word of tmux's own
command syntax, which is not a shell's. An argument of the plainest characters
goes as it is; any other is single-quoted, and inside single quotes tmux takes
every character as itself - `#`, `\$`, `~`, `{`, `;` and `\\` included - with a
quote written as `'\\''`, quoted strings running together into one word as in
a shell. Measured on 3.5a: `'y;'` is `y;`, `'a\\;'` is `a\\;`, `'it'\\''s'` is
`it's`, `'a#b'` is `a#b`.
"""
function mux_line(args::AbstractVector{<:AbstractString})
    io = IOBuffer()
    for (i, a) in enumerate(args)
        i == 1 || print(io, ' ')
        if !isempty(a) && all(ch -> isascii(ch) && (isletter(ch) || isdigit(ch) || ch in "-_./=@%+,:"), a)
            print(io, a)
        else
            print(io, '\'', replace(String(a), "'" => "'\\''"), '\'')
        end
    end
    String(take!(io))
end

"""
    mux_alive(name) -> Bool

Whether a session of exactly this name exists.

`-t=name` is the exact form. Plain `-t name` is a pattern, and a session named
for one thing would otherwise answer for another whose name extends it.
"""
mux_alive(name::AbstractString) = first(mux("has-session", "-t=" * name))

"""
    mux_start(name, dir, cmd; set = []) -> (ok, err)

Start a detached session running `cmd` in `dir`, unless it is already up.

Detached is what makes this reusable: the session exists whether or not anyone
is looking at it, so attaching is a separate decision made later, possibly
several times.

`set` is [`standalone`](@ref)'s: what the program is to be handed, whatever
the server holds.

A child that fails - exits non-zero, or never runs at all - leaves its pane
behind (`remain-on-exit failed`), so that what it said is still there to be
read: an agent whose command was not found used to end its session before
anything could attach, and the only word left was that nothing could. One
that exits cleanly ends the session as before. The option is set before the
command runs, and not after: the session starts on `cat`, which waits, and
`respawn-pane -k` puts `cmd` in its place - down the pipe each command is its
own round trip, and a command that fails at exec is gone inside one. A server
too old to know `failed` (before 3.3) keeps nothing, as before.
"""
function mux_start(name::AbstractString, dir::AbstractString, cmd::AbstractString;
                   set = Pair{String,String}[])
    mux_alive(name) && return (true, "")
    ok, err = mux("new-session", "-d", "-s", name, "-c", dir, "cat")
    ok || return (false, isempty(err) ? "could not start session" : err)
    t = string("=", name, ":")
    mux("set-option", "-w", "-t", t, "remain-on-exit", "failed")
    # One trailing argument, so tmux hands the whole thing to a shell. Passing
    # it pre-split would make the caller quote for a shell it cannot see.
    ok, err = mux("respawn-pane", "-k", "-t", t, "-c", dir, standalone(cmd; set))
    ok && return (true, "")
    mux_kill(name)
    (false, isempty(err) ? "could not start session" : err)
end

"""
    standalone(cmd; set) -> String

Wrap `cmd` so its child starts with `set`, `name => value` pairs, whatever the
server holds.

`env` at exec, because the tmux *server* keeps the environment it was started
with and hands every session a copy: that copy is the one thing a session
command cannot change, and a variable set on the *session* reaches only what is
started in it afterwards, never the program already running. The values are
single-quoted for the shell tmux runs the command through, so they are handed
over as they are, not expanded - a host that wants `\$PATH` in one has to put
the actual path there.
"""
function standalone(cmd::AbstractString; set = Pair{String,String}[])
    isempty(set) && return String(cmd)
    words = ["env"]
    append!(words, (string(k, "=", shq(v)) for (k, v) in set))
    push!(words, String(cmd))
    join(words, ' ')
end

"""Single-quote a shell word, the one quoting every shell reads the same way."""
shq(s::AbstractString) = string("'", replace(String(s), "'" => "'\\''"), "'")

"""
    mux_kill(name) -> Bool

End a session and everything running in it.
"""
mux_kill(name::AbstractString) = first(mux("kill-session", "-t=" * name))

"""
    mux_tag!(name; kwargs...) -> Bool

Record what a session *is*, as against what it is called.

A name carries whatever was worth labelling it with, and those things change
under a session that has never moved - a branch gets renamed, something else
gets opened on the same checkout. So the name is a label and these are the
identity. Each keyword becomes a `@`-prefixed user option on the session, which
[`mux_list`](@ref) reads back.

    mux_tag!(name; worktree = path, kind = :agent, item = "julia#123")

One `mux` for all of them: one process joined by `;`, or one line each down
the pipe. A value ending in `;` is the character, however it goes - see
[`mux_spawn`](@ref).
"""
function mux_tag!(name::AbstractString; kwargs...)
    isempty(kwargs) && return true
    cmds = Vector{String}[]
    for (k, v) in pairs(kwargs)
        push!(cmds, String["set", "-t", String(name), string("@", k), string(v)])
    end
    first(mux(cmds))
end

"""
    mux_rename(old, new) -> Bool

Rename a session, or do nothing when the name has not changed.
"""
mux_rename(old::AbstractString, new::AbstractString) =
    old == new || first(mux("rename-session", "-t=" * old, String(new)))

"""
    mux_sessions(prefix) -> Vector{String}

Every session named under `prefix` - `prefix-...`, as [`mux_name`](@ref) makes
them - by name.
"""
function mux_sessions(prefix::AbstractString)
    ok, out = mux("list-sessions", "-F", "#{session_name}")
    ok || return String[]
    p = string(prefix, "-")
    filter(n -> startswith(n, p), split(strip(out), '\n'; keepempty = false))
end

"""One session, as [`mux_list`](@ref) reads it.

`id` is the server's own for the session, `\$3`: it stays put through a
rename, which the name does not, and is never reused while the server runs -
a restart starts over at `\$0`, but a restart ends every session too. `tags`
are the values of the user options `mux_list` was asked for, in that order,
`""` for one never set; what they mean is the host's.
"""
struct MuxRow
    name::String
    id::String
    command::String
    attached::Bool
    bell::Bool
    tags::Vector{String}
end

"""
    mux_list(prefix, tags = String[]) -> Vector{MuxRow}

Every session named under `prefix`, with what is running in each.

One call, and only the active pane of each session: the list is a summary, and a
session with three windows is still one line of it.

`tags` names the user options set by [`mux_tag!`](@ref) to read back, as the
host names them; their values come back in `tags`, in the same order, beside
`name`, `id`, `command`, `attached` and `bell`. An argument and not a setting:
the tags are the host's schema, and a host that keeps them in one place types
its rows there. Rows come back sorted by name.

`bell` is tmux's own unread mark: the child rang the terminal bell while nobody
was attached, and nobody has attached since. Measured on 3.5a rather than read
off the manual: a bell with a client attached sets nothing, since somebody was
looking; one rung into a detached session sets the flag; the next attach clears
it - a control-mode attach the same as any other. That is exactly a seen bit,
kept by the server the session lives in, so a child that rings when it wants
attention - a hook on the end of an agent's turn - is a child whose rows can
say so without a listener of its own. `monitor-bell` is on by default and is
the user's to turn off. [`mux_seen!`](@ref) clears it and [`mux_ring!`](@ref)
sets it, for a host whose own marks have to agree with it.

The tags are matched here rather than with a tmux filter expression: a path can
contain the characters a format string is made of, and a comma in a checkout's
name would otherwise quietly match nothing.
"""
function mux_list(prefix::AbstractString,
                  tags::AbstractVector{<:AbstractString} = String[])
    fmt = join(vcat(["#{session_name}", "#{session_id}", "#{pane_current_command}",
                     "#{session_attached}", "#{window_bell_flag}"],
                    String["#{@" * t * "}" for t in tags]), '\t')
    ok, out = mux("list-panes", "-a",
                  "-f", "#{&&:#{window_active},#{pane_active}}", "-F", fmt)
    ok || return MuxRow[]
    n = 5 + length(tags)
    p = string(prefix, "-")
    rows = MuxRow[]
    for line in split(out, '\n'; keepempty = false)
        f = split(line, '\t')
        length(f) == n || continue
        startswith(f[1], p) || continue
        push!(rows, MuxRow(String(f[1]), String(f[2]), String(f[3]), f[4] != "0", f[5] == "1",
                           String[String(x) for x in f[6:end]]))
    end
    sort!(rows; by = r -> r.name)
    rows
end

"""
    mux_seen!(name) -> Bool

Clear the session's bell flag, as looking at it would.

Nothing but an attach clears the flag - `select-window` returns early on the
window that is already current, and there is no command for the flag itself -
so this is one: a control-mode client on a closed stdin, which the server
counts as somebody looking and which is gone on the next read (4 ms on 3.5a).
For a host whose read mark and tmux's have to say the same thing: a mark that
left the bell standing would leave the row unread whatever was pressed.
"""
mux_seen!(name::AbstractString) = first(mux_spawn("-C", "attach", "-t=" * String(name)))

"""
    mux_ring!(name) -> Bool

Ring the session's bell, as its child would: a `BEL` on the pane's tty.

The other half of [`mux_seen!`](@ref), for undoing it. Written to the tty and
not sent as keys: `send-keys` is input to the child, and this is output from
it. The flag is set only if nobody is attached, which is the rule for any bell.
"""
function mux_ring!(name::AbstractString)
    # `-t name`, not `-t=name`: `display-message` takes `=name` without a
    # word and prints an empty line for it. `mux_name` has no `=` to collide.
    ok, tty = mux("display", "-p", "-t", String(name), "#{pane_tty}")
    (ok && !isempty(strip(tty))) || return false
    try
        open(io -> write(io, '\a'), strip(tty), "w")
        true
    catch
        false
    end
end

"""
    mux_attach(name; suspend) -> Bool

Show `name` full screen, however the host is being run.

Two different things, because attaching depends on where we already are.

Outside tmux there is a terminal to give away, and `suspend` gives it: it is
called with a zero-argument function and must put the terminal back the way the
child expects it - raw mode off, alternate screen left - and restore the host's
own screen afterwards.

Inside tmux there is not. `tmux attach` refuses to nest, and would fail with
`sessions should be nested with care` even though the session is right there on
the same server. What is wanted is the client we are already running under
pointed at the other session, which is `switch-client`, and it returns at once
rather than blocking until the user is finished - tmux's own binding brings them
back, and the host is left running in the session it was always in.
"""
function mux_attach(name::AbstractString; suspend = f -> f())
    cmd = mux_cmd("attach", "-t=" * String(name))
    cmd === nothing && return false
    if !isempty(get(ENV, "TMUX", ""))
        # Spawned, never down the pipe: it moves the client that asked.
        first(mux_spawn("switch-client", "-t=" * name)) && return true
        # A session on another server cannot be switched to; fall through and
        # try to attach, which will at least say why.
    end
    suspend() do
        try
            run(cmd)
        catch
            # Ctrl-C in the child, or a server that went away while attached.
            # Neither is worth a backtrace over the restored screen.
        end
    end
    true
end
