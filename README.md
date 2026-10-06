# TermIFrame.jl

[Documentation](https://vtjnash.github.io/TermIFrame.jl/dev/): this README, and every
docstring.

An iframe for the terminal: another program, running in a tmux session, drawn
inside a box your own TUI lays out.

The name is the design. An HTML `<iframe>` embeds a document the host page does
not understand, sizes it, and forwards events into it; the document scrolls and
draws inside its own rectangle and knows nothing about what is around it. This
is that, for a terminal.

A tmux session is what makes it possible. It holds a program that outlives the
view of it, and its screen can be read back **as text** — so the host never has
to understand a single escape sequence the child emits. `vi`, a pager, a build
and an agent are the same amount of work, a program this does not know about is
no work at all, and the child keeps running when you look away.

You do not need tmux installed: `tmux_jll` is a dependency, and its binary is
what this runs. `PATH` is deliberately not consulted — a tmux binary holds no
sessions (they live in a server addressed by a socket, so `tmux ls` in your own
shell lists the ones started here regardless), and the protocol version has been
8 for the whole of tmux 3.x, so the bundled client and an installed server talk
to each other anyway. What is left to gain is knowing which build you are
talking to, and one known version beats whatever happens to be installed.
`MUX_ENV[]`'s variable is the override.

```julia
using TermIFrame

mux_start("demo", pwd(), "htop")
f = iframe("demo", "htop")
c = f.client
@async (while mux_wait(c); redraw(); end; redraw())   # output, and the end

box = iframe_box(w, h)                   # the child's (cols, rows) inside your box
iframe_sync!(f, box)                     # size it, read its screen back
rows = iframe_rows(f, w, h)              # `h` rows of exactly `w` columns
write(stdout, frame_bytes(rows))         # TermInput's frame, the child's rows as they are
r = iframe_input!(f, bytes, iframe_origin(x, y), box)
while r isa UInt8                         # the key typed after ^]
    your_key!(f, r)                      # leave, kill, full screen: yours
    r = iframe_input!(f, UInt8[], iframe_origin(x, y), box)
end
```

The host hands in no functions. It waits on the client for output and reads what
changed off the iframe: `client` gone to `nothing` after a sync is the child
having exited, and `iframe_input!` answering a byte is the key typed after `^]`,
which is the host's to act on - with `iframe_close!`, `mux_kill`,
`mux_attach(f.name; suspend)`, `iframe_sync!` or `iframe_send!` - before it
calls `iframe_input!` again to send on what was read after it, or
`iframe_discard!` when the key took the keyboard somewhere else.

What a host writes on every call is exported. The rest - `bordered`, `mux`, the
control client under the iframe, the protocol under that - is `public` and not
exported, because those are names a host may have already or a layer it only
reaches for to build something other than an iframe: `import TermIFrame:
bordered` where it is wanted.

## What it does that a bare `tmux attach` does not

* **The host owns the layout.** Nothing here asks `displaysize`; every function
  that needs geometry is told it. An iframe drawn in a column beside something
  else is the case that matters.
* **Scrollback the child does not have.** `capture-pane` reads the grid, so a
  box showing a shell that has just printed a build log had no way to look back
  at it. A wheel report the child did not ask for scrolls the host's window over
  the pane's own history instead, and so do shift- and ctrl-PgUp/PgDn, a page
  at a time, off the alternate screen.
* **A drag that selects, as tmux's own does.** Over a child that did not ask for
  the mouse, a drag is tmux's copy mode - tmux is what knows a wrapped line from
  two, and joins the one when it copies. A control client cannot hand tmux the
  drag and `capture-pane` never reads the mode's screen, so the mode is driven
  by its commands and drawn here from its formats (`CopyMode`,
  `copy_selected`); the copy goes into tmux's buffers and onto the terminal's
  clipboard. Copy mode the pane was already in is drawn the same way.
* **Mouse reports that land where they should.** A report arrives in screen
  coordinates and the child owns a box inside that screen; forwarded unchanged,
  a click lands somewhere else, and usually plausibly so. And a child that never
  turned mouse reporting on is sent nothing, because it would print the escape
  sequence as the control characters it is.
* **The clipboard gets through.** OSC 52 paints no cell, so it is not in the
  grid and never can be — a program several terminals down that copies something
  has no other way to reach the terminal a person is looking at. It is relayed;
  nothing else is, because everything else would draw over the host's frame.
* **One prefix key.** `^]` is the only key the child never gets: with every
  other byte forwarded, Escape and `^C` included, the way out cannot be a key a
  program would want. The key after it is handed to the host, which decides
  what each one means: this finds the prefix - never inside a paste, and across
  two reads - and nothing more.
* **A control-mode client, not a process per keystroke.** One `tmux -C attach`
  over a pipe pair: a `tmux` process per key and per frame costs a fork each
  time (~5ms against ~1ms) and has no way to be *told* something changed — it can
  only ask.

## What TermInput gives it

The border is drawn with `TermInput`'s box characters and faces,
`CHROME[]` - so an iframe beside a composer or a dialog is bordered the way it
is, and a host that sets them moves both. The rows are `TermInput`'s too: a
`Row` is an annotated string, faces over text, measured by its text, and
`iframe_rows` and `bordered` answer them for `TermInput.frame_bytes` to write.

A captured screen is not parsed into one. It is a child program's raw SGR and
OSC 8 hyperlinks as tmux gave them, and a round trip through faces would lose
what a face cannot say - blink, overline, a palette index past fifteen - so a
row of it is a `verbatim` piece of the box's row: written as it is, as wide as
the pane it was read from, and never measured, cut or restyled after the one
thing done to it here, copy mode's selection painted in. tmux sized the pane to
the box, so each row fits; `frame_bytes` closes a piece after writing it and
moves the cursor past its width, however little of it tmux filled.

Both halves come through [`TermInput.jl`](https://github.com/vtjnash/TermInput.jl),
which is this package's only dependency besides `tmux_jll`: a text field needs
exactly the same measuring for exactly the same reason, and the dependency goes
that way round because a text field must not pull a tmux binary in to measure a
string. What reads a child's escapes is here and not there, and only reads
them: `ESCAPE` steps over one, and `unescaped(row)` is a captured row's text,
for counting characters in it.

## Sessions

Naming, starting, tagging and listing are separate from drawing, which is what
lets a session outlive every client that has looked at it.

```julia
n = mux_name("app", "julia", "master", "62841"; kind = :agent)  # app-julia-master-62841-agent
mux_start(n, checkout, "claude")
mux_tag!(n; worktree = checkout, kind = :agent, item = "JuliaLang/julia#62841")

mux_list("app", ["worktree", "kind", "item"])  # every session under app-, with those tags
mux_attach(n; suspend = f -> give_the_terminal_away(f))
```

A name is a *label*: the things worth naming a session after change under a
session that has not moved. What a session **is** lives in its tags, which
`mux_list` reads back on each row, in the order it was asked for them. Each row
carries the server's `id` for the session too, which a rename does not change.

The prefix is the first part of a name and the argument every listing takes:
it is what a host lists its own sessions by, so that one started by hand is not
its to list or kill. Nothing holds a host to one - two prefixes are two sets of
sessions, listed apart.

A session does not end when its child does. The pane is kept with what the
child said and its status under it, and its row of `mux_list` says `dead`
until the host ends it. An iframe opened on one shows that screen with the
status in `exited`, and `iframe_close!` on it ends the session; `mux_kill`
ends any.

## The command pipe

Every session command is a `tmux` process by default, ~3 ms each. A host that
issues many - a dashboard listing its sessions, tagging them, marking them read -
opens one control-mode client for all of them:

```julia
import TermIFrame: mux
mux_pipe_open("app")  # once a session under app- exists
mux(...)              # every command goes down it while it is open, 0.04-0.16 ms
mux_pipe_close()      # when the last session has ended, and on exit
```

A control client has to be attached to stay open, and attaching to a session
clears its bell, so the pipe is parked on a session of its own,
`_<prefix>-ctl-<pid>`, which ends with it. `tmux ls` shows it like any other;
the host's listings skip it, since it is named outside the prefix. It also subscribes to the bells of
every session under that prefix: `mux_wait` on the pipe returns when one rings
or is heard, or when a session starts or ends (`sessions` on the client), so a
host hears a bell without listing the sessions on a clock. A child exiting is
heard there as well (`MUX_DEAD` in the client's `subs`), which is how a host
drawing that pane learns of it - nothing ended, so the pane's own client is
told nothing - and syncs its iframe. `switch-client` and
the attach behind `mux_seen!` are always spawned: they are about the client
that asks.

## Configuration

| | |
|---|---|
| `MUX_ENV[]` | the environment variable naming a tmux binary to use instead of the bundled `tmux_jll` one |
| `IFRAME_PREFIX` | the prefix byte, `^]` |

## Windows

`tmux_jll` has no build for Windows, so `mux_bin` returns `nothing` there and
the session-backed tests skip rather than fail. Under WSL2 this does not come
up at all: a real Linux tmux server runs underneath and everything above works
exactly as it does on Linux or macOS, which is the supported way to run this on
a Windows machine today.

A native backend — no WSL2, no Linux tmux underneath — was looked at and set
aside. `tmux` itself has no Windows build to bundle. A package calling itself
`psmux` turned up in searches for an alternative and does not hold up: the repo
carries an `llms.txt` and an `AGENTS.md` written to be read by coding agents
rather than people, a false claim of automatic Claude Code integration, star
and fork counts implausible for its age, and "independent" comparison posts
from the same account that publishes it. Whatever the binary itself does, a
project shaped to get an AI agent to install and vouch for it is not one this
depends on.

The other candidate was building on ConPTY directly. ConPTY has no server of
its own — the pseudoconsole lives only as long as the process that created it,
so "a session outlives every client that has looked at it" is not something the
platform gives you; it is something tmux's server provides on top, and would
have to be built again from nothing to get the same property on Windows.
[WezTerm](https://github.com/wezterm/wezterm) has already built that once, and
`wezterm-mux-server --daemonize` really does run detached from any GUI. But
tried by hand: panes spawned into it while no client was attached — the case
this package needs, a session nobody is looking at right now — were torn down
by the server within a second, `get-text` included, every time except the very
first. Its CLI is also a process-per-command interface with no raw-byte send
and no push notifications, the opposite of the persistent, hex-keyed, control
mode connection `control.jl` is built around. Native Windows support stays
undone until there is a backend that actually holds a session open unattended.

## Tests

```bash
julia --project=. test/runtests.jl
```

The protocol, the naming, the escaping and the geometry are pure functions and
run with no tmux and no tty. The rest drives a real server, which `tmux_jll`
supplies where none is installed — so on any platform it builds for, everything
runs with no setup at all. Where it does not build (Windows), those testsets
skip rather than fail.

`TERMIFRAME_TMUX` points the whole suite at a particular binary, which is how to
check a build other than the bundled one.

## Documentation

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

builds the site - with `TermInput.jl` checked out beside this, as for the tests - into `docs/build`: this README as its first page, and
every docstring after it. CI builds it on every push and publishes `main`'s at
the link at the top.

## License

MIT. Copyright (c) 2026 JuliaHub, Inc. and Jameson Nash.
