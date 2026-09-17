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
    mux_name(parts...; kind = :shell, prefix = "wl") -> String

What to *call* a session, out of the parts that say which one it is.

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
function mux_name(parts::AbstractString...; kind::Symbol = :shell,
                  prefix::AbstractString = MUX_PREFIX[])
    clean(x) = replace(String(x), '.' => '_', ':' => '_')
    out = [String(prefix)]
    for p in parts
        isempty(p) || push!(out, clean(p))
    end
    kind === :shell || push!(out, String(kind))
    join(out, '-')
end

"""The prefix every session this program owns is named with.

It is what makes a session *ours*: [`mux_sessions`](@ref) and [`mux_list`](@ref)
list only these, because a session someone started by hand is not a host
program's to list or to kill. Set it once, to something short and yours.
"""
const MUX_PREFIX = Ref("iframe")

"""
    mux(args...) -> (ok, output)

Run one multiplexer command.

Never throws: every caller is on a keystroke path where a missing binary or a
dead server has to become a status line, not a backtrace.
"""
function mux(args::AbstractString...)
    cmd = mux_cmd(args...)
    cmd === nothing && return (false, no_mux())
    try
        out = read(pipeline(cmd; stderr = devnull), String)
        (true, out)
    catch e
        (false, e isa ProcessFailedException ? "" : first(sprint(showerror, e), 80))
    end
end

"""
    mux_alive(name) -> Bool

Whether a session of exactly this name exists.

`-t=name` is the exact form. Plain `-t name` is a pattern, and a session named
for one thing would otherwise answer for another whose name extends it.
"""
mux_alive(name::AbstractString) = first(mux("has-session", "-t=" * name))

"""
    mux_start(name, dir, cmd; scrub = SCRUB_PREFIXES[], set = []) -> (ok, err)

Start a detached session running `cmd` in `dir`, unless it is already up.

Detached is what makes this reusable: the session exists whether or not anyone
is looking at it, so attaching is a separate decision made later, possibly
several times.

`scrub` and `set` are [`standalone`](@ref)'s: what the program is not to
inherit, and what it is to be handed instead.
"""
function mux_start(name::AbstractString, dir::AbstractString, cmd::AbstractString;
                   scrub = SCRUB_PREFIXES[], set = Pair{String,String}[])
    mux_alive(name) && return (true, "")
    # One trailing argument, so tmux hands the whole thing to a shell. Passing
    # it pre-split would make the caller quote for a shell it cannot see.
    ok, err = mux("new-session", "-d", "-s", name, "-c", dir, standalone(cmd; scrub, set))
    ok ? (true, "") : (false, isempty(err) ? "could not start session" : err)
end

"""Environment-variable prefixes to unset in an embedded program's environment.

Defaults to the agent variables, which is the case this was written for: run a
host from inside an agent and every child inherits that agent's session -
`CLAUDE_CODE_CHILD_SESSION`, which silently turns the child's transcript saving
off, and `CLAUDE_CODE_MESSAGING_SOCKET` and its token, which are the parent's
control channel. A program started in an iframe is meant to be its own session,
answerable to the person watching it and to nobody else, and a shell has no more
business holding another session's credentials.

Set to `String[]` to inherit everything.
"""
const SCRUB_PREFIXES = Ref(["CLAUDE"])

"""
    standalone(cmd; scrub, set) -> String

Wrap `cmd` so its child starts as if from a plain terminal.

The names are read from this process rather than listed, so whatever a future
version inherits is scrubbed too, and nothing is scrubbed that was not actually
there. `env -u` does it at exec, which is the only place that certainly
applies: the tmux *server* keeps the environment it was started with, and every
session it is asked for later would otherwise be handed a copy.

`set` is the other direction, `name => value` pairs the child is to start
with, whatever the server holds. The same `env` does both, and for the same
reason: the server's copy of the environment is the one thing a session
command cannot change, and a variable set on the *session* reaches only what
is started in it afterwards, never the program already running. The values
are single-quoted for the shell tmux runs the command through, so they are
handed over as they are, not expanded - a host that wants `\$PATH` in one has
to put the actual path there.
"""
function standalone(cmd::AbstractString; scrub = SCRUB_PREFIXES[],
                    set = Pair{String,String}[])
    vars = isempty(scrub) ? String[] :
           sort!([k for k in keys(ENV) if any(p -> startswith(k, p), scrub)])
    isempty(vars) && isempty(set) && return String(cmd)
    words = ["env"]
    append!(words, ("-u " * v for v in vars))
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
"""
function mux_tag!(name::AbstractString; kwargs...)
    ok = true
    for (k, v) in pairs(kwargs)
        ok &= first(mux("set", "-t", name, string("@", k), string(v)))
    end
    ok
end

"""
    mux_rename(old, new) -> Bool

Rename a session, or do nothing when the name has not changed.
"""
mux_rename(old::AbstractString, new::AbstractString) =
    old == new || first(mux("rename-session", "-t=" * old, String(new)))

"""
    mux_sessions(; prefix) -> Vector{String}

Every session this program owns, by name.
"""
function mux_sessions(; prefix::AbstractString = MUX_PREFIX[])
    ok, out = mux("list-sessions", "-F", "#{session_name}")
    ok || return String[]
    p = string(prefix, "-")
    filter(n -> startswith(n, p), split(strip(out), '\n'; keepempty = false))
end

"""
    mux_list(; tags, prefix) -> Vector{NamedTuple}

Every session this program owns, with what is running in each.

One call, and only the active pane of each session: the list is a summary, and a
session with three windows is still one line of it.

`tags` names the user options set by [`mux_tag!`](@ref) to read back; each
becomes a field of the row, alongside `name`, `command` and `attached`. Rows
come back sorted by name.

The tags are matched here rather than with a tmux filter expression: a path can
contain the characters a format string is made of, and a comma in a checkout's
name would otherwise quietly match nothing.
"""
function mux_list(; tags = (:worktree, :kind, :item),
                  prefix::AbstractString = MUX_PREFIX[])
    tags = Tuple(Symbol(t) for t in tags)
    fmt = join(vcat(["#{session_name}", "#{pane_current_command}", "#{session_attached}"],
                    ["#{@$t}" for t in tags]), '\t')
    ok, out = mux("list-panes", "-a",
                  "-f", "#{&&:#{window_active},#{pane_active}}", "-F", fmt)
    ok || return NamedTuple[]
    n = 3 + length(tags)
    p = string(prefix, "-")
    rows = NamedTuple[]
    for line in split(out, '\n'; keepempty = false)
        f = split(line, '\t')
        length(f) == n || continue
        startswith(f[1], p) || continue
        vals = (; (t => String(f[3 + i]) for (i, t) in enumerate(tags))...)
        push!(rows, merge((name = String(f[1]), command = String(f[2]),
                           attached = f[3] != "0"), vals))
    end
    sort!(rows; by = r -> r.name)
    rows
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
        first(mux("switch-client", "-t=" * name)) && return true
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
