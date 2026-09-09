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

@testset "TermIFrame" begin

@testset "naming a session" begin
    # All the parts, in the order they were given, under the host's prefix.
    withenv() do
        MUX_PREFIX[] = "wl"
        @test mux_name("julia", "master", "62841") == "wl-julia-master-62841"
        @test mux_name("julia", "master", "62841"; kind = :agent) ==
              "wl-julia-master-62841-agent"

        # Empty parts are dropped rather than leaving a doubled separator.
        @test mux_name("julia", "", "62841") == "wl-julia-62841"
        @test mux_name("julia") == "wl-julia"

        # tmux does not reject `.` or `:` in a session name, it rewrites them to
        # `_` and says nothing. A name that did not do the same substitution
        # would create a session and then never find it again.
        @test mux_name("Distributed.jl", "", "198") == "wl-Distributed_jl-198"
        @test mux_name("a:b") == "wl-a_b"
        # `/` it leaves alone, which is what lets a branch keep its owner prefix.
        @test mux_name("julia-wt2", "vtjnash/fix", "1") == "wl-julia-wt2-vtjnash/fix-1"

        MUX_PREFIX[] = "demo"
        @test mux_name("x") == "demo-x"
        MUX_PREFIX[] = "iframe"
    end
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
        @test mux_sessions() == String[]
        @test mux_list() == NamedTuple[]
        @test iframe("anything", "t") === nothing
    end
end

@testset "the environment an embedded program starts with" begin
    # A program started in an iframe is its own session, and has no business
    # holding the credentials of the one that launched it. The names are read
    # from this process, so nothing is scrubbed that was not there.
    withenv("CLAUDE_CODE_CHILD_SESSION" => "1", "CLAUDE_CODE_TOKEN" => "x") do
        s = standalone("bash")
        @test startswith(s, "env -u ")
        @test occursin("-u CLAUDE_CODE_CHILD_SESSION", s)
        @test occursin("-u CLAUDE_CODE_TOKEN", s)
        @test endswith(s, " bash")
        # And a host that wants to inherit everything says so.
        @test standalone("bash"; scrub = String[]) == "bash"
    end
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
    # than being sent on half-written.
    @test passthrough("\e]52;c;aGk=") == String[]
    # And nothing else is relayed: echoing anything that draws would be writing
    # over a screen the host lays out itself.
    @test passthrough("\e]0;a title\a") == String[]
    @test passthrough("\e[2J\e[H") == String[]
end

# The escape-aware measuring these draw against is `TermInput`'s now, and so is
# its suite: `awidth`, `afit`, `apad`, `amid` and `awrap` are tested where they
# live. What is below is this package's use of them.

@testset "the box round it" begin
    # Every row exactly the width asked for, and exactly as many rows.
    for (w, h) in ((30, 5), (80, 24), (12, 3))
        rs = bordered(["\e[32mgreen\e[0m plain", "second"], w, h, "demo", true)
        @test length(rs) == h
        @test all(awidth(r) == w for r in rs)
    end
    # The content is in there, colour and all, and the title with it.
    rs = bordered(["\e[32mgreen\e[0m"], 30, 4, "demo", true)
    @test occursin("green", join(rs)) && occursin("\e[32m", join(rs))
    @test occursin("demo", astrip(rs[1]))
    # A title too long for the box is cut rather than pushing the corner off.
    rs = bordered(String[], 20, 3, "a title far too long to fit in here", false)
    @test all(awidth(r) == 20 for r in rs)
    # And the box characters are Term's, which is what makes this a plugin
    # rather than a wrapper: the theme's box is what a `Term.Panel` uses.
    @test occursin(string(TermIFrame.iframe_box_style().top.left), astrip(rs[1]))
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
    MUX_PREFIX[] = "tif"

    @testset "a child program in a box" begin
        n = mux_name("test", "screen")
        mux_kill(n)
        @test first(mux_start(n, pwd(),
            "sh -c 'printf \"\\033[1;32mgreen\\033[0m plain\\n\"; sleep 120'"))
        # Starting one that is already up is not an error, and does not restart it.
        @test mux_start(n, pwd(), "true") == (true, "")
        @test mux_alive(n) === true
        @test n in mux_sessions()

        f = iframe(n, "demo")
        @test f !== nothing
        cols, rows = iframe_box(80, 24)
        @test iframe_sync!(f, cols, rows) === true
        @test f.sized == (cols, rows)
        @test length(f.frame) == rows              # the height it was just given
        @test occursin("green", join(f.frame))
        @test occursin("\e[", join(f.frame))       # colour kept, not stripped
        # Every row is closed off, or an unterminated colour would run out of
        # the content and into the border.
        @test all(endswith(l, "\e[0m") for l in f.frame)

        out = iframe_rows(f, 80, 24)
        @test length(out) == 24 && all(awidth(r) == 80 for r in out)

        # A different size re-sizes the child, not just the box round it.
        cols2, rows2 = iframe_box(120, 40)
        iframe_sync!(f, cols2, rows2)
        @test f.sized == (cols2, rows2)
        @test length(f.frame) == rows2
        out = iframe_rows(f, 120, 40)
        @test length(out) == 40 && all(awidth(r) == 120 for r in out)

        # Tags are what a session *is*, as against what it is called, and they
        # come back on the row.
        @test mux_tag!(n; worktree = pwd(), kind = :shell, item = "demo#1")
        r = only(filter(x -> x.name == n, mux_list()))
        @test r.worktree == pwd() && r.kind == "shell" && r.item == "demo#1"
        # An open iframe *is* an attached client, which is what `attached`
        # reports - a host drawing a session and a person looking at it full
        # screen are the same thing to tmux.
        @test r.attached === true

        # `^]q` lets go of the child and leaves the session running - that is
        # what a session is for.
        @test iframe_input!(f, [IFRAME_PREFIX, UInt8('q')], (3, 2), (cols2, rows2)) === :pop
        @test mux_alive(n) === true

        # `^]K` is the one that ends it.
        f2 = iframe(n, "demo")
        @test f2 !== nothing
        @test iframe_input!(f2, [IFRAME_PREFIX, UInt8('K')], (3, 2), (cols2, rows2)) === :pop
        @test mux_alive(n) === false
    end

    @testset "a host takes the keys it wants and leaves the rest" begin
        n = mux_name("test", "keys")
        mux_kill(n)
        mux_start(n, pwd(), "sleep 120")
        f = iframe(n, "demo")
        box = iframe_box(80, 24)
        iframe_sync!(f, box...)

        seen = UInt8[]
        oncommand = b -> begin
            b == UInt8('\t') && (push!(seen, b); return :ok)
            b in IFRAME_KEYS && return :unhandled
            push!(seen, b)
            :ok
        end
        # A key the host claims does not leave, even though the package's own
        # answer to it would be to.
        @test iframe_input!(f, [IFRAME_PREFIX, UInt8('\t')], (3, 2), box;
                            oncommand) === :ok
        @test seen == [UInt8('\t')]
        # One it does not name is the package's, and `^]?` says what those are.
        @test iframe_input!(f, [IFRAME_PREFIX, UInt8('?')], (3, 2), box;
                            oncommand) === :ok
        @test f.status == iframe_keys()
        # And anything left over reaches the host.
        @test iframe_input!(f, [IFRAME_PREFIX, UInt8('o')], (3, 2), box;
                            oncommand) === :ok
        @test seen == [UInt8('\t'), UInt8('o')]

        iframe_close!(f)
        mux_kill(n)
    end

    @testset "the wheel over a child that ignores it" begin
        # `capture-pane` reads the grid, so an iframe had no scrollback at all:
        # a shell that had just printed a build log could not be looked back at.
        # The wheel reports were arriving and being dropped, because a report
        # forwarded to a program that never asked for one prints as the control
        # characters it is - so the ones nobody wanted are the ones this answers.
        n = mux_name("test", "scrollback")
        mux_kill(n)
        mux_start(n, pwd(), "sh -c 'seq 1 500; sh'")
        f = iframe(n, "sh")
        box = iframe_box(100, 30)
        origin = iframe_origin(1, 1)
        # Waited for rather than slept through: a fixed sleep was long enough
        # until it was not, and a `seq` that had not finished left every
        # assertion below measuring an empty history.
        for _ in 1:40
            iframe_sync!(f, box...)
            f.history > 100 && break
            sleep(0.25)
        end
        @test f.wantsmouse === false          # a shell asked for nothing
        @test f.alt === false && f.history > 100
        live = astrip(first(f.frame))
        wheel(b) = collect(codeunits(string("\e[<", b, ";", origin[1] + 5, ";",
                                            origin[2] + 5, "M")))

        iframe_input!(f, wheel(64), origin, box)
        @test f.scroll == WHEEL_ROWS
        # The window moved by exactly what the wheel says it moved by.
        @test parse(Int, astrip(first(f.frame))) == parse(Int, live) - WHEEL_ROWS
        # No cursor while looking at the past: it is not on these rows.
        @test iframe_cursor(f, origin, box) === nothing
        # And the note says where you are, over anything else it might say.
        f.status = "something happened"
        @test occursin("rows back", iframe_note(f))
        f.status = ""

        iframe_input!(f, wheel(65), origin, box)
        @test f.scroll == 0 && astrip(first(f.frame)) == live

        # Shift- and ctrl-wheel are the same request refined, not a different
        # one, so they scroll rather than falling through.
        for b in (64 + 4, 64 + 16)
            f.scroll = 0
            @test iframe_wheel!(f, b) === true && f.scroll == WHEEL_ROWS
        end
        f.scroll = 0

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

    @testset "the child exiting is told once" begin
        n = mux_name("test", "onend")
        mux_kill(n)
        mux_start(n, pwd(), "sh -c 'sleep 0.3'")
        calls = Ref(0)
        f = iframe(n, "brief"; onend = () -> (calls[] += 1; "it finished"))
        box = iframe_box(40, 10)
        for _ in 1:40
            iframe_sync!(f, box...)
            f.client === nothing && break
            sleep(0.25)
        end
        @test f.client === nothing
        @test calls[] == 1 && f.status == "it finished"
        # And never again from a later sync: an editor's file is read back when
        # it exits, and reading it twice would undo an edit made in between.
        iframe_sync!(f, box...)
        @test calls[] == 1
        # What the child left behind outranks saying it has gone: that it ended
        # is the less useful of the two things to be told.
        @test iframe_note(f) == "it finished"
        f.status = ""
        @test occursin(n, iframe_note(f)) && occursin("K to kill", iframe_note(f))
        # And the box still draws with no child behind it.
        out = iframe_rows(f, 40, 10)
        @test length(out) == 10 && all(awidth(r) == 40 for r in out)
        mux_kill(n)
    end

    MUX_PREFIX[] = "iframe"
end

end # testset TermIFrame
