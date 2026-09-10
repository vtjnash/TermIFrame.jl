# TermIFrame.jl

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
f = iframe("demo", "htop"; onwake = () -> redraw())

cols, rows = iframe_box(w, h)            # the child's size inside your box
iframe_sync!(f, cols, rows)              # size it, read its screen back
for line in iframe_rows(f, w, h)         # `h` rows of exactly `w` columns
    println(line)
end
iframe_input!(f, bytes, iframe_origin(x, y), (cols, rows))
```

## What it does that a bare `tmux attach` does not

* **The host owns the layout.** Nothing here asks `displaysize`; every function
  that needs geometry is told it. An iframe drawn in a column beside something
  else is the case that matters.
* **Scrollback the child does not have.** `capture-pane` reads the grid, so a
  box showing a shell that has just printed a build log had no way to look back
  at it. A wheel report the child did not ask for scrolls the host's window over
  the pane's own history instead.
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
  program would want. `^]q` leaves, `^]K` kills, `^]a` goes full screen, `^]r`
  rereads, `^]]` sends a literal `^]`, `^]?` says so. A host claims its own keys
  through `oncommand`, and everything it does not claim stays the package's.
* **A control-mode client, not a process per keystroke.** One `tmux -C attach`
  over a pipe pair: a `tmux` process per key and per frame costs a fork each
  time (~5ms against ~1ms) and has no way to be *told* something changed — it can
  only ask.

## What Term gives it

The border is drawn with Term's box characters, following
`Term.TERM_THEME[].box` — so an iframe beside a `Term.Panel` is bordered the way
that panel is, and changing the theme moves both.

The measuring is not Term's, and deliberately so. `Panel` measures markup, and a
captured screen is not markup: it is a child program's raw SGR and OSC 8
hyperlinks, which markup measurement counts as characters. Content that fits
gets wrapped, and the panel then elides its own tail. So `awidth`, `afit` and
`apad` work against real display widths, and Term supplies the glyphs.

Both halves come through [`TermInput.jl`](https://github.com/vtjnash/TermInput.jl),
which is this package's only dependency besides `tmux_jll`: a text field needs
exactly the same measuring for exactly the same reason, and the dependency goes
that way round because a text field must not pull a tmux binary in to measure a
string. `awidth`, `astrip`, `afit`, `apad`, `amid` and `awrap` are re-exported
here, so a host laying an iframe out beside something else has them.

## Sessions

Naming, starting, tagging and listing are separate from drawing, which is what
lets a session outlive every client that has looked at it.

```julia
MUX_PREFIX[] = "wl"                       # the sessions this program owns
n = mux_name("julia", "master", "62841"; kind = :agent)
mux_start(n, checkout, "claude")
mux_tag!(n; worktree = checkout, kind = :agent, item = "julia#62841")

mux_list()          # every session under the prefix, with its tags
mux_attach(n; suspend = f -> give_the_terminal_away(f))
```

A name is a *label*: the things worth naming a session after change under a
session that has not moved. What a session **is** lives in its tags, which
`mux_list` reads back as fields on each row.

`SCRUB_PREFIXES` is what an embedded program starts without. It defaults to the
agent variables: run a host from inside an agent and every child would otherwise
inherit that agent's session and its control channel, and a program started in
an iframe is meant to be its own session, answerable to the person watching it
and to nobody else.

## Configuration

| | |
|---|---|
| `MUX_PREFIX[]` | the prefix naming the sessions this host owns; only these are listed or killed |
| `MUX_ENV[]` | the environment variable naming a tmux binary to use instead of the bundled `tmux_jll` one |
| `SCRUB_PREFIXES[]` | environment-variable prefixes an embedded program starts without |
| `IFRAME_PREFIX` | the prefix byte, `^]` |
| `IFRAME_KEYS` | the bytes after it that are the package's, and a host must not shadow |

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

## License

MIT. Copyright (c) 2026 JuliaHub, Inc. and Jameson Nash.
