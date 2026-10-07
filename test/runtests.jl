# What can be tested without a terminal.
#
# The protocol is a pure function of lines, the geometry a pure function of a
# size, and the drawing a pure function of a captured screen - so all three run
# with no tmux and no tty. What is left needs a real server, and is guarded on
# there being one: `TERMIFRAME_TMUX` points at a binary, or `tmux` is on `PATH`.
#
#     julia --project=. test/runtests.jl

using Test
using TermIFrame
# Public and not exported, so imported by name, as a host would.
import TermIFrame: mux, mux_cmd, mux_spawn, mux_line, bundled_tmux, standalone,
    MUX_BG, MuxProto, mux_feed!, mux_unescape, passthrough, mux_open,
    mux_continue!, mux_relay!, mux_sync!, mux_ask, mux_capture, mux_pane_state,
    CopyMode, copy_selected, mux_paste, mux_brackets, mux_resize, mux_keys,
    mux_close, MUX_PIPE, MUX_BELLS, MUX_TITLES, MUX_DEAD, pipe_session, mux_version,
    bordered, iframe_wheel!, page_keys!, iframe_drag!, retarget_mouse, WHEEL_ROWS, DRAG_SCROLL, PAUSE_AFTER,
    ESCAPE, unescaped

import TermInput
import TermInput: Row, faced, verbatim, rowwidth, frame_bytes
import StyledStrings: Face, SimpleColor
# What StyledStrings writes for a row, which is what the terminal is sent.
ansi(r::AbstractString) = sprint(print, r; context = :color => true)

@testset "TermIFrame" begin

@testset "naming a session" begin
    # All the parts, in the order they were given, under the host's prefix.
    @test mux_name("wl", "julia", "master", "62841") == "wl-julia-master-62841"
    @test mux_name("wl", "julia", "master", "62841"; kind = :agent) ==
          "wl-julia-master-62841-agent"

    # Empty parts are dropped rather than leaving a doubled separator.
    @test mux_name("wl", "julia", "", "62841") == "wl-julia-62841"
    @test mux_name("wl", "julia") == "wl-julia"

    # tmux does not reject `.` or `:` in a session name, it rewrites them to
    # `_` and says nothing. A name that did not do the same substitution
    # would create a session and then never find it again.
    @test mux_name("wl", "Distributed.jl", "", "198") == "wl-Distributed_jl-198"
    @test mux_name("wl", "a:b") == "wl-a_b"
    # `/` it leaves alone, which is what lets a branch keep its owner prefix.
    @test mux_name("wl", "julia-wt2", "vtjnash/fix", "1") == "wl-julia-wt2-vtjnash/fix-1"

    @test mux_name("demo", "x") == "demo-x"
end

@testset "which binary, and why not the one on PATH" begin
    # The bundled one, unless the variable names another. `PATH` is not
    # consulted: a tmux binary holds no sessions - they live in a server
    # addressed by a socket, so any binary that opens it sees the same ones -
    # and the protocol version has been 8 for the whole of tmux 3.x, so the
    # bundled client and an installed server talk to each other. What is left is
    # knowing which build we are talking to, and one is easier than whatever
    # happens to be installed.
    withenv(MUX_ENV[] => nothing) do
        @test something(mux_bin(), "none") == something(bundled_tmux(), "none")
        # Even with something else first on `PATH`, which is the whole claim.
        mktempdir() do d
            withenv("PATH" => string(d, Sys.iswindows() ? ';' : ':', ENV["PATH"])) do
                @test something(mux_bin(), "none") == something(bundled_tmux(), "none")
            end
        end
    end
    # The variable is the override, and it is taken literally: a path that is
    # not there means there is no tmux, not "look somewhere else".
    withenv(MUX_ENV[] => "/nonexistent/tmux") do
        @test mux_bin() === nothing
    end
    # On every platform `tmux_jll` builds for - everything but Windows - there
    # is one whether or not anything is installed.
    if bundled_tmux() !== nothing
        @test isfile(bundled_tmux())
        withenv(MUX_ENV[] => nothing) do
            @test mux_bin() !== nothing
        end
    else
        @info "no tmux_jll build for this platform; there is no tmux here at all"
    end
end

@testset "no binary is an answer, not an error" begin
    # Every caller is on a keystroke path, so a missing binary has to become a
    # status line rather than a backtrace.
    withenv(MUX_ENV[] => "/nonexistent/tmux") do
        @test mux_bin() === nothing
        ok, err = mux("list-sessions")
        @test ok === false && occursin("no tmux", err)
        @test mux_alive("anything") === false
        @test mux_sessions("wl") == String[]
        @test mux_list("wl") == MuxRow[]
        @test iframe("anything", "t") === nothing
    end
end

@testset "the environment an embedded program starts with" begin
    # What it is handed, whatever the server holds: quoted for the shell tmux
    # runs it through, so a value is a value and never a word to expand.
    @test standalone("bash") == "bash"
    s = standalone("bash"; set = ["SSH_AUTH_SOCK" => "/run/a.sock", "X" => "it's \$HOME"])
    @test s == "env SSH_AUTH_SOCK='/run/a.sock' X='it'\\''s \$HOME' bash"
end

@testset "a command as a control line" begin
    # tmux's own syntax, not a shell's: plain words go as they are, anything
    # else single-quoted, inside which every character is itself.
    @test mux_line(["list-panes", "-a", "-t=wl-x:", "@url"]) == "list-panes -a -t=wl-x: @url"
    @test mux_line(["display", "-p", "#{pane_tty}"]) == "display -p '#{pane_tty}'"
    @test mux_line(["set", "@x", "y;"]) == "set @x 'y;'"
    @test mux_line(["set", "@x", "it's"]) == raw"set @x 'it'\''s'"
    @test mux_line(["set", "@x", ""]) == "set @x ''"
    @test mux_line(["x", "~ \$HOME {a}"]) == "x '~ \$HOME {a}'"
end

@testset "the control-mode protocol" begin
    p = MuxProto()
    @test mux_feed!(p, "%begin 1 2 1") == (:more, nothing, nothing)
    @test mux_feed!(p, "one") == (:more, nothing, nothing)
    kind, ok, lines = mux_feed!(p, "%end 1 2 1")
    @test (kind, ok, lines) == (:reply, true, ["one"])

    # `%error` closes a block too, and says it failed.
    mux_feed!(p, "%begin 2 3 1")
    @test mux_feed!(p, "%error 2 3 1") == (:reply, false, String[])

    # A line inside a block is not a notification even when it starts with `%`:
    # a capture of a screen with a percent sign on it would otherwise be read as
    # protocol.
    mux_feed!(p, "%begin 3 4 1")
    @test mux_feed!(p, "%output not-really") == (:more, nothing, nothing)
    @test mux_feed!(p, "%end 3 4 1") == (:reply, true, ["%output not-really"])

    # Output arrives unasked, with the pane it came from.
    @test mux_feed!(p, "%output %5 hi") == (:output, "%5", "hi")
    # And under `pause-after`, as `%extended-output`, with how far behind it
    # is before the data.
    @test mux_feed!(p, "%extended-output %5 12 : a\\040b") == (:output, "%5", "a b")
    @test mux_feed!(p, "%extended-output %5 12 : ") == (:output, "%5", "")
    @test mux_feed!(p, "%pause %5") == (:notice, "pause", "%5")
    # Anything else `%` is a notice.
    @test mux_feed!(p, "%exit ") == (:notice, "exit", "")
    @test mux_feed!(p, "%sessions-changed") == (:notice, "sessions-changed", "")
    # And a stray line outside every block is nothing at all.
    @test mux_feed!(p, "loose") == (:more, nothing, nothing)
end

@testset "the escaping tmux applies to output" begin
    # Only bytes below 0x20 and the backslash itself, as three octal digits.
    @test mux_unescape("a\\011b") == "a\tb"
    @test mux_unescape("a\\134b") == "a\\b"
    @test mux_unescape("\\033[1m") == "\e[1m"
    # Everything from 0x20 up passes through raw, UTF-8 continuation bytes and
    # DEL included, so this works on bytes and leaves what it does not recognise
    # exactly as it found it.
    @test mux_unescape("héllo") == "héllo"
    @test mux_unescape("a\\9zz") == "a\\9zz"
    @test mux_unescape("plain") == "plain"
end

@testset "what the screen cannot carry" begin
    # `capture-pane` reads the grid, and a sequence that paints no cell is not
    # in it. The clipboard is the one that matters: a program several terminals
    # down has no other way to reach the terminal a person is looking at.
    @test passthrough("") == String[]
    @test passthrough("nothing here") == String[]
    @test passthrough("a\e]52;c;aGk=\ab") == ["\e]52;c;aGk=\a"]
    # ST terminates it as well as BEL.
    @test passthrough("\e]52;c;aGk=\e\\") == ["\e]52;c;aGk=\e\\"]
    # Several, in order.
    @test passthrough("\e]52;c;YQ==\a-\e]52;c;Yg==\a") ==
          ["\e]52;c;YQ==\a", "\e]52;c;Yg==\a"]
    # A truncated one is left for the rest of it to arrive next time, rather
    # than being sent on half-written - and with a carry, it does: tmux cuts a
    # pane's stream into `%output` lines of a few kilobytes wherever it happens
    # to be, and a clipboard of a few paragraphs is past the first cut. Before
    # the carry a long copy was lost whole.
    @test passthrough("\e]52;c;aGk=") == String[]
    carry = Ref("")
    long = "\e]52;c;" * "QUJD"^600 * "\a"
    @test passthrough(carry, long[1:1000]) == String[]
    @test passthrough(carry, long[1001:end]) == [long]
    @test carry[] == ""
    # Cut inside the introducer, and inside the ST terminator.
    @test passthrough(carry, "x\e]5") == String[]
    @test passthrough(carry, "2;c;aGk=\ay") == ["\e]52;c;aGk=\a"]
    @test passthrough(carry, "\e]52;c;aGk=\e") == String[]
    @test passthrough(carry, "\\y") == ["\e]52;c;aGk=\e\\"]
    # A line ending in an escape that turns out to be something else is let go.
    @test passthrough(carry, "\e[2J\e") == String[]
    @test passthrough(carry, "[H") == String[]
    @test carry[] == ""
    # What claude writes inside tmux: the copy raw and again inside a DCS
    # passthrough with its escapes doubled, and a cut through each. Both come
    # out whole, and the doubled escape is not part of either.
    stream = long * "\ePtmux;\e" * replace(long, "\e" => "\e\e") * "\e\\"
    @test vcat(passthrough(carry, stream[1:800]),
               passthrough(carry, stream[801:3000]),
               passthrough(carry, stream[3001:end])) == [long, long]
    # Bytes need not be UTF-8.
    @test passthrough(carry, String(UInt8[0xff, 0x1b])) == String[]
    @test passthrough(carry, String(UInt8[0xfe])) == String[]
    # And nothing else is relayed: echoing anything that draws would be writing
    # over a screen the host lays out itself.
    @test passthrough("\e]0;a title\a") == String[]
    @test passthrough("\e[2J\e[H") == String[]
end

# The measuring these draw against is `TermInput`'s, and so is its suite:
# `rowwidth`, `rowfit`, `rowpad` and `verbatim` are tested where they live.
# What is below is this package's use of them.

@testset "the box round it" begin
    green = faced("green", Face(foreground = SimpleColor(:green)))
    # Every row exactly the width asked for, and exactly as many rows.
    for (w, h) in ((30, 5), (80, 24), (12, 3))
        rs = bordered([TermInput.rowcat(green, " plain"), "second"], w, h, "demo"; focused = true)
        @test length(rs) == h
        @test all(rowwidth(r) == w for r in rs)
        @test all(r -> textwidth(TermIFrame.unescaped(ansi(r))) == w, rs)
    end
    # The content is in there, colour and all, and the title with it.
    rs = bordered([green], 30, 4, "demo"; focused = true)
    @test occursin("green", join(String.(rs))) && occursin("\e[32m", join(ansi.(rs)))
    @test occursin("demo", String(rs[1]))
    # A screen's row is somebody else's escapes, carried as they are and taken
    # at the width it says: never measured, cut into or restyled.
    raw = "\e[31mred\e[1m and more"
    rs = bordered([verbatim(raw, 26)], 30, 3, "demo")
    @test rowwidth(rs[2]) == 30 && occursin(raw, ansi(rs[2]))
    @test occursin(string(raw, "\e[0m\e[29G"), String(frame_bytes(rs)))
    # A title too long for the box is cut rather than pushing the corner off.
    rs = bordered(String[], 20, 3, "a title far too long to fit in here";
                  focused = false)
    @test all(rowwidth(r) == 20 for r in rs)
    # And the box characters are `CHROME[].box`, which is what the host's
    # composers and dialogs are drawn with too.
    @test occursin(string(TermIFrame.boxstyle().top.left), String(rs[1]))
    # A gutter mark stands in the left border and its pad, on its row alone;
    # the rows keep their width, and a mark too wide for the two columns is
    # left off rather than cut to an ellipsis.
    ml = string(TermIFrame.boxstyle().mid.left)
    rs = bordered(["one", "two", "three"], 20, 5, "g"; focused = true,
                  gutter = ["", faced("💬", Face(foreground = SimpleColor(:cyan))), "wide!"])
    @test all(rowwidth(r) == 20 for r in rs)
    @test startswith(String(rs[2]), ml * " one")
    @test startswith(String(rs[3]), "💬two") && occursin("\e[36m💬", ansi(rs[3]))
    @test startswith(String(rs[4]), ml * " three")
    # The faces a host passes paint the whole iframe, border and footer: the
    # footer painted from the global while the border took the argument would
    # be one box in two sets of faces.
    ch = (strong = Face(foreground = SimpleColor(:red)), quiet = Face(foreground = SimpleColor(:green)),
          focus = Face(inverse = true), box = TermIFrame.boxstyle())
    rs = iframe_rows(IFrame("n", "t"), 30, 6; focused = false, chrome = ch)
    @test length(rs) == 6 && all(rowwidth(r) == 30 for r in rs)
    @test startswith(ansi(rs[1]), "\e[32m") && startswith(ansi(rs[end]), "\e[32m")
    @test !any(r -> occursin("\e[2m", ansi(r)), rs)
end

@testset "the box the child is given" begin
    # Two rows of border plus the footer, and four columns of border and padding.
    @test iframe_box(80, 24) == (76, 21)
    @test iframe_box(120, 40) == (116, 37)
    @test iframe_box(2, 2) == (1, 1)          # never asks for a zero size
    # The child's first cell is inside both the border and the padding.
    @test iframe_origin(1, 1) == (3, 2)
    @test iframe_origin(40, 1) == (42, 2)
end

# --- with a server ----------------------------------------------------------

# With `tmux_jll` a dependency this is only ever taken on a platform it has no
# build for, and then only when nothing is installed either - but it is still a
# skip and not a failure, because "there is no tmux here" is a thing this
# package has an answer for rather than a thing that breaks it.
if mux_bin() === nothing
    @info "no tmux; skipping the tests that need a server"
else
    # The prefix the sessions here are named under, and listed by.
    P = "tif"

    @testset "a child program in a box" begin
        n = mux_name(P, "test", "screen")
        mux_kill(n)
        @test first(mux_start(n, pwd(),
            "sh -c 'printf \"\\033[1;32mgreen\\033[0m plain\\n\"; sleep 120'"))
        # Starting one that is already up is not an error, and does not restart it.
        @test mux_start(n, pwd(), "true") == (true, "")
        @test mux_alive(n) === true
        @test n in mux_sessions(P)

        f = iframe(n, "demo")
        @test f !== nothing
        cols, rows = iframe_box(80, 24)
        @test iframe_sync!(f, (cols, rows)) === true
        @test f.sized == (cols, rows)
        @test length(f.frame) == rows              # the height it was just given
        @test occursin("green", join(f.frame))
        @test occursin("\e[", join(f.frame))       # colour kept, not stripped
        out = iframe_rows(f, 80, 24)
        @test length(out) == 24 && all(rowwidth(r) == 80 for r in out)
        # Every row of the screen is in the box as it was read, and closed
        # when it is written, or an unterminated colour would run out of the
        # content and into the border.
        fb = String(frame_bytes(out))
        @test all(l -> occursin(string(l, "\e[0m\e[", 3 + cols, "G"), fb), f.frame)

        # A different size re-sizes the child, not just the box round it.
        cols2, rows2 = iframe_box(120, 40)
        iframe_sync!(f, (cols2, rows2))
        @test f.sized == (cols2, rows2)
        @test length(f.frame) == rows2
        out = iframe_rows(f, 120, 40)
        @test length(out) == 40 && all(rowwidth(r) == 120 for r in out)

        # Tags are what a session *is*, as against what it is called, and they
        # come back on the row.
        @test mux_tag!(n; worktree = pwd(), kind = :shell, item = "demo#1")
        tags = ["worktree", "kind", "item", "url"]
        r = only(filter(x -> x.name == n, mux_list(P, tags)))
        # In the order they were asked for; a tag never set reads back empty.
        @test r.tags == [pwd(), "shell", "demo#1", ""]
        @test startswith(r.id, '$')
        # A value ending in `;` is a separator to tmux unless it is escaped.
        @test mux_tag!(n; url = "https://example.com/1", item = "x;")
        r = only(filter(x -> x.name == n, mux_list(P, tags)))
        @test r.tags[3:4] == ["x;", "https://example.com/1"]
        # A title the child never set is the host name, which says nothing.
        @test r.title == "" && f.childtitle == ""
        # One it did is read back whole, the separators of both formats in it
        # and all, and goes on the iframe's border after the host's own.
        # `select-pane -T` is what an OSC 2 from the child does.
        t = "\u2733 Count, to forty"
        @test first(mux("select-pane", "-t", string("=", n, ":"), "-T", t))
        r = only(filter(x -> x.name == n, mux_list(P, tags)))
        @test r.title == t
        @test r.tags == [pwd(), "shell", "x;", "https://example.com/1"]
        iframe_sync!(f, (cols2, rows2))
        @test f.childtitle == t
        @test occursin(string("demo  \u00b7  ", t), String(first(iframe_rows(f, 120, 40))))
        # The id is the session's, whatever it is called.
        @test mux_rename(n, n * "-r")
        @test only(filter(x -> x.name == n * "-r", mux_list(P))).id == r.id
        @test mux_rename(n * "-r", n)
        @test isempty(only(filter(x -> x.name == n, mux_list(P))).tags)
        # An open iframe *is* an attached client, which is what `attached`
        # reports - a host drawing a session and a person looking at it full
        # screen are the same thing to tmux.
        @test r.attached === true

        # Letting go of the child leaves the session running - that is what a
        # session is for.
        @test iframe_input!(f, [IFRAME_PREFIX, UInt8('q')], (3, 2), (cols2, rows2)) === UInt8('q')
        iframe_close!(f)
        @test mux_alive(n) === true

        # A bell rung with nobody attached is kept by tmux until somebody is:
        # `bell` is the server's own seen bit, and attaching is what reads it.
        row() = only(filter(x -> x.name == n, mux_list(P)))
        @test row().attached === false && row().bell === false
        @test row().dead === false             # its child is running
        ring() = (@test mux_ring!(n); sleep(0.2))
        ring()
        @test row().bell === true
        # A host's own read mark clears it without anyone attaching for long.
        @test mux_seen!(n)
        @test row().bell === false && row().attached === false
        ring()
        @test row().bell === true

        # Killing it is the one that ends it.
        f2 = iframe(n, "demo")
        @test f2 !== nothing
        @test row().attached === true && row().bell === false
        # And with a client looking, a bell marks nothing: it was seen.
        ring()
        @test row().bell === false
        iframe_close!(f2)
        @test mux_kill(n) && mux_alive(n) === false
    end

    @testset "the key after the prefix is the host's" begin
        # A child that records what reaches it.
        n = mux_name(P, "test", "keys")
        mux_kill(n)
        out = tempname()
        mux_start(n, pwd(), string("sh -c 'stty raw -echo; cat > ", out, "'"))
        f = iframe(n, "keys")
        box = iframe_box(80, 24)
        sleep(0.5)
        iframe_sync!(f, box)
        b(s) = collect(codeunits(s))
        # What was typed before the prefix goes to the child; the key after it
        # is the answer; what was read after the key waits for the host.
        @test iframe_input!(f, vcat(b("ab"), [IFRAME_PREFIX], b("zcd")), (3, 2), box) === UInt8('z')
        @test f.held == b("cd")
        # The host answers the key and sends on the rest, with nothing new.
        @test iframe_input!(f, UInt8[], (3, 2), box) === :ok && isempty(f.held)
        # A prefix that ends one read has its key in the next.
        @test iframe_input!(f, vcat(b("e"), [IFRAME_PREFIX]), (3, 2), box) === :ok && f.pending
        @test iframe_input!(f, b("?f"), (3, 2), box) === UInt8('?') && !f.pending
        @test iframe_input!(f, UInt8[], (3, 2), box) === :ok
        # A key that took the keyboard somewhere else has what followed it
        # dropped, and it never reaches the child.
        @test iframe_input!(f, vcat([IFRAME_PREFIX], b("qxy")), (3, 2), box) === UInt8('q')
        iframe_discard!(f)
        @test iframe_input!(f, UInt8[], (3, 2), box) === :ok && isempty(f.held)
        # The prefix itself reaches the child only when the host sends it.
        @test iframe_send!(f, [IFRAME_PREFIX], box)
        sleep(0.5)
        @test read(out, String) == string("abcdef", Char(IFRAME_PREFIX))
        # With the child gone, a key is spent saying so, and then there is none.
        iframe_close!(f)
        mux_kill(n)
        sleep(0.2)
        @test iframe_input!(f, b("x"), (3, 2), box) === :ok
        @test f.client === nothing && occursin("session ended", f.status)
        @test iframe_input!(f, b("x"), (3, 2), box) === :gone
        rm(out; force = true)
    end

    @testset "the wheel over a child that ignores it" begin
        # `capture-pane` reads the grid, so an iframe had no scrollback at all:
        # a shell that had just printed a build log could not be looked back at.
        # The wheel reports were arriving and being dropped, because a report
        # forwarded to a program that never asked for one prints as the control
        # characters it is - so the ones nobody wanted are the ones this answers.
        n = mux_name(P, "test", "scrollback")
        mux_kill(n)
        mux_start(n, pwd(), "sh -c 'seq 1 500; sh'")
        f = iframe(n, "sh")
        box = iframe_box(100, 30)
        origin = iframe_origin(1, 1)
        # Waited for rather than slept through: a fixed sleep was long enough
        # until it was not, and a `seq` that had not finished left every
        # assertion below measuring an empty history.
        for _ in 1:40
            iframe_sync!(f, box)
            f.history > 100 && break
            sleep(0.25)
        end
        @test f.wantsmouse === false          # a shell asked for nothing
        @test f.alt === false && f.history > 100
        live = unescaped(first(f.frame))
        wheel(b) = collect(codeunits(string("\e[<", b, ";", origin[1] + 5, ";",
                                            origin[2] + 5, "M")))

        iframe_input!(f, wheel(64), origin, box)
        @test f.scroll == WHEEL_ROWS
        # The window moved by exactly what the wheel says it moved by.
        @test parse(Int, unescaped(first(f.frame))) == parse(Int, live) - WHEEL_ROWS
        # No cursor while looking at the past: it is not on these rows.
        @test iframe_cursor(f, origin, box) === nothing
        # And the note says where you are, over anything else it might say.
        f.status = "something happened"
        @test occursin("rows back", iframe_note(f))
        f.status = ""

        iframe_input!(f, wheel(65), origin, box)
        @test f.scroll == 0 && unescaped(first(f.frame)) == live

        # Shift- and ctrl-wheel are the same request refined, not a different
        # one, so they scroll rather than falling through.
        for b in (64 + 4, 64 + 16)
            f.scroll = 0
            @test iframe_wheel!(f, b) === true && f.scroll == WHEEL_ROWS
        end
        f.scroll = 0

        # The shifted and controlled page keys are a page of it, and are not
        # typed at the shell, which has nothing bound to them and would print
        # the tail of the sequence.
        page = last(box) - 1
        iframe_input!(f, collect(codeunits("\e[5;5~")), origin, box)
        @test f.scroll == page
        @test parse(Int, unescaped(first(f.frame))) == parse(Int, live) - page
        iframe_input!(f, collect(codeunits("\e[5;2~\e[6;2~\e[6;5~")), origin, box)
        @test f.scroll == 0 && unescaped(first(f.frame)) == live
        # A child on the alternate screen may bind them, and has them.
        f.alt = true
        @test page_keys!(f, collect(codeunits("\e[5;5~"))) ==
              (collect(codeunits("\e[5;5~")), false)
        f.alt = false

        # It stops at the top of the history rather than running past it.
        for _ in 1:(f.history ÷ WHEEL_ROWS + 20)
            iframe_wheel!(f, 64)
        end
        @test f.scroll == f.history

        # Typing snaps back to the live screen, the way a terminal does: what
        # you type is going to the bottom of it.
        iframe_input!(f, UInt8[UInt8(' ')], origin, box)
        @test f.scroll == 0

        # A click is not a wheel, and is still dropped when nothing wants it.
        @test isempty(retarget_mouse(f, collect(codeunits(
            string("\e[<0;", origin[1] + 5, ";", origin[2] + 5, "M"))), origin, box))
        @test f.scroll == 0

        # On the alternate screen there is nothing behind the child but the
        # wreckage of its own redraws, so this refuses.
        f.alt = true
        @test iframe_wheel!(f, 64) === false && f.scroll == 0
        f.alt = false

        # And a child that *did* ask still gets the report, unchanged in meaning
        # and moved into its own coordinates.
        f.wantsmouse = true
        @test retarget_mouse(f, wheel(64), origin, box) ==
              collect(codeunits("\e[<64;6;6M"))
        @test f.scroll == 0                   # answered there, not here
        # A report from outside the box is not the child's and is dropped.
        @test isempty(retarget_mouse(f, collect(codeunits("\e[<0;1;1M")), origin, box))

        iframe_close!(f)
        mux_kill(n)
    end

    @testset "a mouse report with no numbers in it is dropped" begin
        # xterm.js reports a button let go over a terminal it cannot place as
        # `0;NaN;NaN`, and passed on as bytes a shell printed it. Wanted or
        # not, it is nobody's text; what is around it still goes through.
        f = IFrame("n", "t")
        for want in (false, true)
            f.wantsmouse = want
            @test retarget_mouse(f, collect(codeunits("a\e[<0;NaN;NaNmb")), (0, 0), (80, 24)) ==
                  collect(codeunits("ab"))
        end
    end

    @testset "copy mode's coordinates, as tmux counts them" begin
        # The copy mode a drag over a child that ignores the mouse is meant to
        # drive is tmux's own, since tmux is what knows a wrapped line from two.
        # But `capture-pane` reads the pane's grid and never the mode's screen,
        # and a control client cannot hand tmux a mouse event with a position
        # (`send-keys -K` zeroes it, `-M` replays only a bound one) - so the
        # mode is driven by its commands and drawn here from its formats. These
        # are the facts that rests on, measured on 3.5a.
        n = mux_name(P, "test", "copymode")
        mux_kill(n)
        # 500 numbered lines, one line that wraps at 40 columns, and `tail` -
        # then nothing, so that once `tail` is on screen the history is final.
        mux_start(n, pwd(), "sh -c 'seq 1 500; seq -s x 1 30; echo tail; sleep 120'")
        f = iframe(n, "sh")
        box = (40, 10)
        for _ in 1:40
            iframe_sync!(f, box)
            f.history > 100 && any(startswith("tail"), unescaped.(f.frame)) && break
            sleep(0.25)
        end
        c, t = f.client, string(" -t =", n, ":")
        # The view: rows 0-5 are 495-500, 6 and 7 the wrapped line, 8 `tail`.
        rows = unescaped.(f.frame)
        @test rows[1] == "495" && rows[9] == "tail"
        @test length(rows[7]) == 40 && startswith(rows[8], "7x18x")
        hist = f.history
        x!(cmd, k = 0) = first(mux_ask(c, string("send -X", k > 0 ? " -N $k" : "", t, " ", cmd)))
        state() = split(only(last(mux_ask(c, string("display-message -p", t,
            " '#{pane_in_mode},#{scroll_position},#{copy_cursor_x},#{copy_cursor_y},",
            "#{selection_present},#{selection_start_x},#{selection_start_y},",
            "#{selection_end_x},#{selection_end_y},#{history_size},#{selection_active}'")))), ',')
        num(s) = parse(Int, s)
        # Emacs keys, whatever the server's config says: the two differ in
        # whether the cell under the cursor is inside the selection (below).
        @test first(mux_ask(c, string("set -w", t, " mode-keys emacs")))

        @test first(mux_ask(c, "copy-mode" * t))
        s = state()
        @test s[1] == "1" && s[2] == "0"          # in the mode, not scrolled
        @test num(s[10]) == hist                  # the same history the frame counts

        # `copy_cursor_y` is a row of the view; `selection_*_y` is a line of the
        # whole grid, the oldest line of history being 0 - so a view row `r`
        # scrolled back `s` is line `history - s + r`.
        @test x!("top-line") && x!("cursor-down", 5) && x!("cursor-right", 2)
        s = state()
        @test (num(s[3]), num(s[4])) == (2, 5)
        @test x!("begin-selection")
        s = state()
        # Begun and still empty: active, but not yet present - so it is
        # `active` that says a drag is under way, and `present` that there is
        # anything to draw.
        @test s[11] == "1" && s[5] == "0"
        @test (num(s[6]), num(s[7])) == (2, hist + 5)

        # A step down is a row of the screen: a wrapped line is two of them.
        @test x!("cursor-down", 2) && x!("cursor-right", 3)
        s = state()
        @test (num(s[3]), num(s[4])) == (5, 7)
        @test s[5] == "1"
        @test (num(s[8]), num(s[9])) == (5, hist + 7)   # the end follows the cursor

        # Scrolled back, the cursor keeps its view row and the grid line under
        # it changes - which is the same arithmetic run the other way.
        @test x!("scroll-up", 7)
        s = state()
        @test num(s[2]) == 7 && num(s[4]) == 7
        @test num(s[9]) == hist - 7 + 7
        @test x!("scroll-down", 7)

        # What is copied is tmux's to say, and a wrapped line comes out whole.
        # With emacs keys the end is exclusive: the cursor sat on column 5 of
        # `7x18x19...`, and `7x18x` is columns 0-4.
        @test x!("top-line") && x!("cursor-down", 7) && x!("cursor-right", 5)
        @test x!("copy-selection-and-cancel")
        ok, buf = mux_ask(c, "show-buffer")
        @test ok && join(buf, "\n") == "0\n" * rows[7] * "7x18x"
        # The server is yours, so the buffer made here is not left in its list.
        @test first(mux_ask(c, "delete-buffer"))
        @test state()[1] == "0"                   # and the mode is gone

        # `cursor-right` stops at a line's end and one more step wraps it to
        # the next row, so a column past the end has to be clamped to the
        # line's width before it becomes a count: `tail` is four wide, and
        # four steps land on its end where five land on the empty row below.
        @test first(mux_ask(c, "copy-mode" * t))
        @test x!("top-line") && x!("cursor-down", 8) && x!("cursor-right", 4)
        s = state()
        @test (num(s[3]), num(s[4])) == (4, 8)
        @test x!("cursor-right")
        s = state()
        @test (num(s[3]), num(s[4])) == (0, 9)
        # A step down onto a shorter row clamps the column the same way.
        @test x!("top-line") && x!("cursor-down", 7) && x!("cursor-right", 30)
        @test x!("cursor-down")
        s = state()
        @test (num(s[3]), num(s[4])) == (4, 8)
        @test x!("cancel")

        # And whose keys decides the end: one step right of `t` copies `t`
        # with emacs keys and `ta` with vi's, so a highlight drawn from the
        # formats has to ask `mode-keys` which one it is showing.
        for (keys, want) in (("emacs", "t"), ("vi", "ta"))
            @test first(mux_ask(c, string("set -w", t, " mode-keys ", keys)))
            @test first(mux_ask(c, "copy-mode" * t))
            @test x!("top-line") && x!("cursor-down", 8)
            @test x!("begin-selection") && x!("cursor-right")
            @test x!("copy-selection-and-cancel")
            @test only(last(mux_ask(c, "show-buffer"))) == want
            @test first(mux_ask(c, "delete-buffer"))
        end

        iframe_close!(f)
        mux_kill(n)
    end

    @testset "a drag over a child that ignores the mouse is tmux's copy mode" begin
        n = mux_name(P, "test", "drag")
        mux_kill(n)
        mux_start(n, pwd(), "sh -c 'seq 1 500; seq -s x 1 30; echo tail; sleep 120'")
        # The terminal it is drawn on, where the clipboard is relayed - a
        # buffer, rather than the terminal running the tests.
        term = IOBuffer()
        f = iframe(n, "sh"; out = term)
        box, origin = (40, 10), iframe_origin(1, 1)
        for _ in 1:40
            iframe_sync!(f, box)
            f.history > 100 && any(startswith("tail"), unescaped.(f.frame)) && break
            sleep(0.25)
        end
        c = f.client
        @test first(mux_ask(c, string("set -w -t =", n, ": mode-keys emacs")))
        @test f.wantsmouse === false
        rows, hist = unescaped.(f.frame), f.history
        # A report at the child's cell `(x, y)`, 0-based.
        sgr(b, x, y, fin = 'M') = collect(codeunits(string("\e[<", b, ";",
            origin[1] + x, ";", origin[2] + y, fin)))
        # What the sync writes - the clipboard - while `g` runs.
        caught(g) = (take!(term); g(); String(take!(term)))

        # A press alone is nothing, as in tmux, and a release after it copies
        # nothing either.
        out = caught(() -> begin
            @test iframe_input!(f, sgr(0, 2, 5), origin, box) === :ok
            @test f.copy === nothing && f.press == (2, 5)
            iframe_input!(f, sgr(0, 2, 5, 'm'), origin, box)
        end)
        @test f.copy === nothing && f.press === nothing
        @test !occursin("\e]52;", out)

        # The first motion is the mode, begun at the cell pressed: from `0` of
        # `500` to column 4 of the wrapped line's second row.
        iframe_input!(f, sgr(0, 2, 5), origin, box)
        iframe_input!(f, sgr(32, 4, 7), origin, box)
        @test f.copy !== nothing && f.dragging
        @test f.copy.sel == (2, hist + 5, 4, hist + 7)
        # Drawn here, since tmux draws it nowhere this can read: `500` from its
        # `0`, the first row of the wrapped line whole, and its second up to
        # column 4 - emacs keys, so not including it.
        @test occursin("50\e[7m0", f.frame[6])
        @test startswith(f.frame[7], "\e[7m")
        @test occursin("\e[7m7x18\e[27mx", f.frame[8])
        @test unescaped(f.frame[8]) == rows[8]           # painted, not changed
        # The real cursor is copy mode's, and the note says where you are.
        @test iframe_cursor(f, origin, box) == (origin[2] + 7, origin[1] + 4)
        @test occursin("copy mode", iframe_note(f))

        # Up comes the button: copied, onto the clipboard, and the mode gone.
        out = caught(() -> iframe_input!(f, sgr(0, 4, 7, 'm'), origin, box))
        want = "0\n" * rows[7] * "7x18"
        @test occursin(string("\e]52;c;", TermIFrame.base64encode(want), "\a"), out)
        @test join(last(mux_ask(c, "show-buffer")), "\n") == want   # tmux's buffer too
        @test first(mux_ask(c, "delete-buffer"))
        @test f.copy === nothing && !f.dragging && f.scroll == 0

        # A column past a line's end is its end, not the next row: `tail` from
        # its `i` to column 30 copies `il`.
        out = caught(() -> begin
            iframe_input!(f, sgr(0, 2, 8), origin, box)
            iframe_input!(f, sgr(32, 30, 8), origin, box)
            @test f.copy.sel == (2, hist + 8, 4, hist + 8)
            iframe_input!(f, sgr(0, 30, 8, 'm'), origin, box)
        end)
        @test occursin(TermIFrame.base64encode("il"), out)
        @test first(mux_ask(c, "delete-buffer"))

        # Dragged past the top, the view scrolls a row under it; the wheel
        # moves the mode's view while it is up; and the view stays where the
        # mode had got to once it has gone. The ticker held off, so that a row
        # of its own does not land among them.
        was = DRAG_SCROLL[]
        DRAG_SCROLL[] = 60.0
        out = caught(() -> begin
            iframe_input!(f, sgr(0, 0, 3), origin, box)
            iframe_input!(f, sgr(32, 0, -1), origin, box)
            @test f.copy.scroll == 1
            @test f.copy.sel == (0, hist + 3, 0, hist - 1)
            # Moving across past the edge scrolls no further: that is the
            # ticker's, not the motion's.
            iframe_input!(f, sgr(32, 2, -1), origin, box)
            @test f.copy.scroll == 1
            iframe_input!(f, sgr(64, 5, 5), origin, box)
            @test f.copy.scroll == 1 + WHEEL_ROWS
            iframe_input!(f, sgr(0, 0, -1, 'm'), origin, box)
        end)
        DRAG_SCROLL[] = was
        @test f.ticker === nothing
        @test f.copy === nothing && f.scroll == 1 + WHEEL_ROWS
        @test occursin("\e]52;", out)
        @test first(mux_ask(c, "delete-buffer"))
        # Typing is back to the live screen, as it always was.
        iframe_input!(f, UInt8[UInt8(' ')], origin, box)
        @test f.scroll == 0

        # Held past the bottom without moving, the drag goes on scrolling, a
        # row each time the ticker wakes the client - the host's own loop,
        # stood in for here - and stops once the pointer is back over the box.
        iframe_input!(f, sgr(0, 0, 3), origin, box)
        iframe_input!(f, sgr(32, 0, 2), origin, box)
        iframe_input!(f, sgr(64, 0, 2), origin, box)      # somewhere to go down to
        back = f.copy.scroll
        @test back >= WHEEL_ROWS
        iframe_input!(f, sgr(32, 0, box[2]), origin, box)
        @test f.copy.scroll == back - 1 && f.ticker !== nothing
        # A wake is also the child's output, which takes no step: waited for
        # until two have been taken, the second needing no motion either.
        t0 = time()
        while f.copy.scroll > back - 3 && time() - t0 < 5
            @test mux_wait(c)
            iframe_sync!(f, box)
        end
        @test f.copy.scroll == back - 3
        @test time() - t0 >= DRAG_SCROLL[]
        iframe_input!(f, sgr(32, 0, 4), origin, box)
        @test f.ticker === nothing
        iframe_input!(f, sgr(0, 0, 4, 'm'), origin, box)
        @test f.copy === nothing && f.scroll == back - 3
        @test first(mux_ask(c, "delete-buffer"))
        iframe_input!(f, UInt8[UInt8(' ')], origin, box)

        # A child that asked for the mouse still gets the drag, unchanged.
        f.wantsmouse = true
        @test retarget_mouse(f, sgr(32, 4, 7), origin, box) ==
              collect(codeunits("\e[<32;5;8M"))
        @test f.copy === nothing

        iframe_close!(f)
        mux_kill(n)
    end

    @testset "a paste is bracketed only for a child that asked" begin
        # Two children that record what reaches them; one of them turns
        # bracketed paste on, as a shell's line editor or an agent does.
        got = Dict{Bool,String}()
        # `#{bracket_paste_flag}` is tmux 3.7's, and the server's to expand.
        knows = something(tryparse(Float64, match(r"[0-9]+\.[0-9]+",
            readchomp(`$(mux_cmd("-V"))`)).match), 0.0) >= 3.7
        for asks in (false, true)
            n = mux_name(P, "test", asks ? "brackets" : "plain")
            mux_kill(n)
            out = tempname()
            mux_start(n, pwd(), string("sh -c 'stty raw -echo; ",
                asks ? "printf \"\\033[?2004h\"; " : "", "cat > ", out, "'"))
            f = iframe(n, "paste")
            box = iframe_box(80, 24)
            sleep(0.5)
            iframe_sync!(f, box)
            # A paste cut three ways by the reads it arrived in, one of them
            # through the end marker, with typing either side. The prefix
            # inside it is text like the rest.
            b(s) = collect(codeunits(s))
            @test iframe_input!(f, b("x\e[200~a\rb \$HOME"), (3, 2), box) === :ok
            @test f.pasting
            # A server that can say whether the child asked streams the paste
            # as it arrives; one that cannot (before tmux 3.7) holds it whole.
            sleep(0.5)
            head = string("x", f.brackets === true ? "\e[200~a\rb \$HOME" :
                               f.brackets === false ? "a\rb \$HOME" : "")
            @test read(out, String) == head
            @test f.brackets === (asks ? true : false) || (f.brackets === nothing && !knows)
            @test iframe_input!(f, vcat(b("\"q\" "), [IFRAME_PREFIX], b("q\e[20")), (3, 2), box) === :ok
            @test iframe_input!(f, b("1~y"), (3, 2), box) === :ok
            @test !f.pasting && !f.pending && isempty(f.held)
            sleep(0.5)
            got[asks] = read(out, String)
            iframe_close!(f)
            mux_kill(n)
            rm(out; force = true)
        end
        text = "a\rb \$HOME\"q\" \x1dq"
        @test got[false] == string("x", text, "y")
        @test got[true] == string("x\e[200~", text, "\e[201~y")
    end

    @testset "the child exiting is the host's to see" begin
        n = mux_name(P, "test", "onend")
        mux_kill(n)
        pipe = mux_pipe_open(P)
        mux_start(n, pwd(), "sh -c 'echo last; sleep 0.3'")
        f = iframe(n, "brief")
        c = f.client
        id = only(filter(x -> x.name == n, mux_list(P))).id
        # The host waits on the client, and reads the screen when it says
        # something. The child's exit is nothing it says: the pane is kept,
        # so no session ends and no `%exit` comes, and the sync its last
        # output wakes is ahead of the exit. The pipe is what is told, and a
        # host woken there syncs.
        woke = Ref(0)
        box = iframe_box(40, 10)
        t = @async (while mux_wait(c); woke[] += 1; end; woke[] += 1)
        @test timedwait(() -> id in split(get(pipe.subs, MUX_DEAD, "")), 5.0) === :ok
        @test !c.dead
        @test iframe_sync!(f, box) === true
        @test f.client === nothing && f.exited == 0
        @test occursin("exited with status 0", f.status)
        @test any(l -> occursin("last", l), unescaped.(f.frame))
        @test timedwait(() -> istaskdone(t), 2.0) === :ok && woke[] >= 1
        # The session is there, with nothing running in it, until the iframe
        # lets go.
        @test only(filter(x -> x.name == n, mux_list(P))).dead
        # And a dead client answers at once, not never.
        @test mux_wait(c) === false
        # A later sync has nothing to find: what the host does about the end is
        # done once, by the host, from the first one.
        @test iframe_sync!(f, box) === false
        # What to do about it is the host's to say, and so are its keys.
        f.status = ""
        @test iframe_note(f) === nothing
        # And the box still draws with no child behind it.
        out = iframe_rows(f, 40, 10)
        @test length(out) == 10 && all(rowwidth(r) == 40 for r in out)
        iframe_close!(f)
        @test !mux_alive(n)

        # Let go of inside the second before the pipe says so - the child's
        # last words on screen and the key pressed on them - the iframe asks
        # the server itself, and ends what has nothing running in it.
        mux_start(n, pwd(), "sh -c 'echo last; sleep 0.3'")
        f = iframe(n, "brief")
        @test iframe_sync!(f, box) === true && f.exited === nothing
        sleep(0.6)
        @test only(filter(x -> x.name == n, mux_list(P))).dead
        @test f.exited === nothing            # no sync since
        iframe_close!(f)
        @test !mux_alive(n)

        # A session that is ended under the iframe - killed, its server gone -
        # is the other way a child goes, and the one with no screen to keep.
        mux_start(n, pwd(), "sleep 120")
        f = iframe(n, "brief")
        c = f.client
        mux_kill(n)
        @test timedwait(() -> c.dead, 5.0) === :ok
        @test iframe_sync!(f, box) === true
        @test f.client === nothing && f.exited === nothing
        @test occursin("session ended", f.status)
        # The pipe is told of that one too: nothing of ours is dead now.
        @test timedwait(() -> isempty(strip(get(pipe.subs, MUX_DEAD, "x"))), 5.0) === :ok
        mux_pipe_close()
    end

    @testset "a host that stops reading has the pane paused, not dropped" begin
        # A terminal that stops taking bytes blocks the host writing to it, and
        # the whole process with it, reader and all. Without `pause-after` tmux
        # drops the client once its output is five minutes old: `session ended:
        # the server said exit: too far behind`, over a session still running.
        n = mux_name(P, "test", "stall")
        mux_kill(n)
        mux_start(n, pwd(), "sh -c 'sleep 0.5; while :; do seq 1 20000; done'")
        f = iframe(n, "flood"; pause = 1)
        c = f.client
        box = iframe_box(40, 10)
        @test iframe_sync!(f, box)
        # The thread stops, as it does behind a blocked write, not the task.
        Libc.systemsleep(4)
        @test timedwait(() -> !isempty(c.paused), 5.0) === :ok
        @test !c.dead
        # The next sync takes it up again and reads the screen.
        @test iframe_sync!(f, box) && f.client === c && isempty(c.paused)
        @test !isempty(f.frame)
        before = c.outputs
        @test timedwait(() -> c.outputs > before, 5.0) === :ok
        @test !c.dead
        mux_kill(n)
    end

    @testset "a child that exits leaves its screen to be read" begin
        # An agent whose command was not found ended its session before it
        # could be attached to, and all that was left to say was that it could
        # not be; one that finished with nobody watching was gone with what it
        # said. The pane is kept, whatever the status, and shown as it went.
        box = iframe_box(60, 12)
        for (cmd, status, said) in (("sh -c 'echo boom; exit 3'", 3, "boom"),
                                    ("no-such-agent", 127, "not found"),
                                    ("echo fine", 0, "fine"))
            n = mux_name(P, "test", "exits")
            mux_kill(n)
            @test first(mux_start(n, pwd(), cmd))
            row() = only(filter(x -> x.name == n, mux_list(P)))
            @test timedwait(() -> row().dead, 5.0) === :ok
            @test mux_alive(n)                     # kept, though nothing runs
            # It is a state and not a bell: nothing rang, and nothing can.
            @test !row().bell && !mux_ring!(n)
            f = iframe(n, "exited")
            @test f !== nothing
            @test iframe_sync!(f, box) === true
            @test f.client === nothing && f.exited == status
            @test occursin(string("status ", status), f.status)
            text = join(unescaped.(f.frame), "\n")
            @test occursin(said, text) && occursin("Pane is dead", text)
            # Looking does not end it; letting go of it does.
            @test row().dead
            # Nothing can be typed at it.
            @test iframe_send!(f, UInt8['x'], box) === false
            iframe_close!(f)
            @test !mux_alive(n) && f.exited === nothing
        end
    end

    @testset "one command pipe for all of them" begin
        mux_pipe_close()
        @test mux_pipe() === nothing
        n = mux_name(P, "test", "pipe")
        mux_kill(n)
        mux_start(n, pwd(), "sleep 120")
        parked = pipe_session(P)
        c = mux_pipe_open(P)
        @test c !== nothing && mux_pipe() === c && mux_pipe_open(P) === c
        @test c.bells                          # 3.2 and up
        # Our own server is no older than ourselves; a version is compared as
        # tmux numbers them, letter last, and one that is not a number is not
        # called older.
        @test MUX_OLDER[] == ("", "")
        @test mux_version("3.4") < mux_version("3.5") < mux_version("3.5a") <
              mux_version("next-3.6") < mux_version("3.10")
        @test mux_version("master") === nothing
        # Outside the prefix: not ours to list, and not counted as one of ours.
        @test !(parked in mux_sessions(P)) && n in mux_sessions(P)
        @test mux_alive(parked)
        # Commands go down it, and answer as a process would.
        before = c.outputs
        @test mux_alive(n) && !mux_alive(n * "-nope")
        @test mux_tag!(n; item = "x;", url = "it's #1 \$HOME")
        r = only(filter(x -> x.name == n, mux_list(P, ["item", "url"])))
        @test r.tags == ["x;", "it's #1 \$HOME"]
        # Looking at the list through the pipe is not looking at a session:
        # a bell stands beside it.
        @test mux_ring!(n)
        sleep(0.2)
        r = only(filter(x -> x.name == n, mux_list(P)))
        @test r.bell && !r.attached
        # And the pipe hears it: the subscription says who rang, within the
        # second tmux checks it in.
        @test timedwait(() -> strip(get(c.subs, MUX_BELLS, "")) == r.id, 5.0) === :ok
        @test mux_seen!(n)
        @test timedwait(() -> isempty(strip(get(c.subs, MUX_BELLS, "x"))), 5.0) === :ok
        # And a title, which a child retitling its pane changes, and nothing
        # else: the session by id, with the words.
        @test timedwait(() -> haskey(c.subs, MUX_TITLES), 5.0) === :ok
        @test strip(c.subs[MUX_TITLES]) == string(r.id, "=")
        @test first(mux("select-pane", "-t", string("=", n, ":"), "-T", "a, b"))
        @test timedwait(() -> strip(get(c.subs, MUX_TITLES, "")) == string(r.id, "=a, b"),
                        5.0) === :ok
        # A session starting or ending is a notice too.
        c.sessions = false
        mux_kill(n)
        @test timedwait(() -> c.sessions, 2.0) === :ok
        @test c.outputs == before              # `no-output`: nothing is drawn here
        # Two tasks asking at once each get their own answer.
        got = [Ref("") for _ in 1:50]
        @sync for (i, g) in enumerate(got)
            @async g[] = strip(last(mux("display-message", "-p", string("q", i))))
        end
        @test [g[] for g in got] == [string("q", i) for i in 1:50]
        # Closing ends its session with it, and commands spawn again:
        # a pipe with nothing left to ask about must not keep a server up.
        mux_pipe_close()
        @test c.dead && mux_pipe() === nothing
        @test !mux_alive(parked)
    end

    @testset "the terminal's background, for a child that asks" begin
        # A child that asks with `OSC 11 ?`, after `wait` seconds, and keeps
        # whatever comes back. A control client has no terminal to answer from,
        # so every answer here is one the host seeded.
        mux_pipe_close()
        dir = mktempdir()
        ask = joinpath(dir, "ask")
        write(ask, "stty raw -echo; sleep \$1; printf '\\033]11;?\\033\\\\'\n",
                   "dd bs=1 count=25 of=\$2 2>/dev/null; sleep 120\n")
        answer(f) = (timedwait(() -> filesize(f) == 25, 5.0); isfile(f) ? read(f, String) : "")
        names = String[]
        start(tag, wait; pipe = "") = begin
            n = mux_name(P, "test", tag)
            mux_kill(n)
            push!(names, n)
            f = joinpath(dir, tag)
            @test first(mux_start(n, pwd(), string("sh ", ask, " ", wait, " ", f); pipe))
            f
        end
        try
            # Heard before anything is running: kept, and on the pane before
            # its child starts, since the child may ask at once.
            @test mux_bg!(P, "rgb:ffff/fafa/f0f0")
            @test !mux_bg!(P, "rgb:ffff/fafa/f0f0")
            f = start("bg-now", 0; pipe = P)
            @test mux_pipe() !== nothing
            @test answer(f) == "\e]11;rgb:ffff/fafa/f0f0\e\\"
            # A change reaches a pane that is already running.
            f = start("bg-changed", 1)
            @test mux_bg!(P, "rgb:1010/2020/3030")
            @test answer(f) == "\e]11;rgb:1010/2020/3030\e\\"
            # A pane started with no pipe to seed it down is seeded as the
            # pipe opens.
            mux_pipe_close()
            f = start("bg-later", 1)
            @test mux_pipe_open(P) !== nothing
            @test answer(f) == "\e]11;rgb:1010/2020/3030\e\\"
        finally
            TermIFrame.MUX_BG[] = ""
            foreach(mux_kill, names)
            mux_pipe_close()
        end
    end

    @testset "a pipe's session outlives only a live host" begin
        # One whose process is gone - a host that died after starting it and
        # before its client was on it - is ended by the next pipe to open.
        mux_pipe_close()
        n = mux_name(P, "test", "keepup")
        mux_start(n, pwd(), "sleep 120")
        pid = first(p for p in 4_000_000:-1:1 if !TermIFrame.pid_alive(p))
        dead = pipe_session(P, pid)
        mux_spawn("new-session", "-d", "-s", dead, "cat")
        @test mux_alive(dead)
        c = mux_pipe_open(P)
        @test c !== nothing && !mux_alive(dead)
        # And one whose client goes away takes its session with it, which is
        # how a host that is killed leaves nothing behind.
        parked = c.name
        close(c.proc.in)
        @test timedwait(() -> !mux_alive(parked), 5.0) === :ok
        mux_pipe_close()
        mux_kill(n)
    end

end

@testset "every exported or public name says what it is" begin
    # A name a host is told to import and cannot ask about is half an API.
    # `names` lists the public names on 1.11 and the exported ones before it.
    # `Docs.hasdoc` is 1.11's. Before it, a docstring is in the `meta` of the
    # module that owns the name - or, for a module, in that module's own.
    function hasdoc(m, n)
        isdefined(Docs, :hasdoc) && return Docs.hasdoc(m, n)
        b = Docs.Binding(m, n)
        v = getfield(m, n)
        haskey(Docs.meta(v isa Module ? v : b.mod), b)
    end
    api = setdiff(names(TermIFrame), [:TermIFrame])
    @test isempty(filter(n -> !hasdoc(TermIFrame, n), api))
    if VERSION >= v"1.11.0-DEV.469"
        # What this file imports by name is public, so a host can too.
        for n in (:mux, :bordered, :passthrough, :mux_open, :mux_keys,
                  :retarget_mouse, :iframe_wheel!, :WHEEL_ROWS, :PAUSE_AFTER)
            @test Base.ispublic(TermIFrame, n)
        end
        # A name a host is likely to have is not pushed into its namespace.
        for n in (:mux, :bordered, :passthrough, :standalone, :ESCAPE)
            @test !Base.isexported(TermIFrame, n)
        end
    end
end

end # testset TermIFrame
