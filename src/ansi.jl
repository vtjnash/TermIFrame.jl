# ANSI-aware measurement, fitting and wrapping, for text this package never
# wrote.
#
# Everything drawn here comes back from `capture-pane`, which means it is a
# child program's own output: colours, hyperlinks and whatever else it felt
# like emitting. Laying a border round that needs the width it will *print* at,
# and `length` and `textwidth` both answer for the escape sequences too.
#
# Term's own measurement is not usable for this. It measures markup - `{bold}`
# and friends - and treats a raw SGR sequence as characters, so a line that fits
# is wrapped and the panel then elides its own tail. So the box is drawn here,
# against real display widths, out of Term's box characters.
#
# Everything a host needs to lay text out beside an iframe is here too, since it
# is the same problem one step out: `amid` for a name in a fixed column, `awrap`
# for a paragraph in a pane. They are what a host would otherwise write again.

"Matches a CSI colour sequence or an OSC 8 hyperlink - what a child emits that
takes no columns."
const ESCAPE = r"^(?:\e\[[0-9;]*[A-Za-z]|\e\][^\e]*\e\\)"

"""
    awidth(s) -> Int

Display width, ignoring escape sequences.
"""
function awidth(s::AbstractString)
    w, i = 0, firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m === nothing
            w += textwidth(s[i]); i = nextind(s, i)
        else
            i += ncodeunits(m.match)
        end
    end
    w
end

"""
    astrip(s) -> String

The same string with every escape sequence taken out - what the screen says, as
against how it looks. What a yank has to produce, and what a test asserts on.
"""
function astrip(s::AbstractString)
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

"""
    afit(s, w) -> String

Truncate to `w` display columns, keeping escapes, and reset style at the cut.
"""
function afit(s::AbstractString, w::Int)
    w <= 0 && return ""
    awidth(s) <= w && return s
    io, acc, i = IOBuffer(), 0, firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m !== nothing
            write(io, m.match); i += ncodeunits(m.match); continue
        end
        cw = textwidth(s[i])
        acc + cw > w - 1 && break
        write(io, s[i]); acc += cw; i = nextind(s, i)
    end
    String(take!(io)) * "…\e[0m"
end

"""
    apad(s, w) -> String

Pad - or cut - to exactly `w` display columns.
"""
apad(s::AbstractString, w::Int) = (d = w - awidth(s); d > 0 ? s * " "^d : afit(s, w))

"""Columns from the front of `s`, without splitting a wide character."""
function ahead(s::AbstractString, w::Int)
    io, acc = IOBuffer(), 0
    for c in s
        cw = textwidth(c)
        acc + cw > w && break
        write(io, c); acc += cw
    end
    String(take!(io))
end

"""Columns from the back of `s`, by the same rule."""
function atail(s::AbstractString, w::Int)
    cs = collect(s)
    acc, i = 0, length(cs) + 1
    while i > 1
        cw = textwidth(cs[i-1])
        acc + cw > w && break
        acc += cw; i -= 1
    end
    String(cs[i:end])
end

"""Fit to `w` display columns by eliding in the *middle*, two thirds of the room
to the head and one third to the tail.

Names in a fixed column agree at the front and differ at the end far more often
than the other way round: branches under one owner prefix, worktrees of one
repo, urls into one issue. Cut at the tail, a pair like that draws as the *same
string* twice, which tells the reader nothing about which is which - and in a
list whose whole job is telling two copies of something apart, that is the one
failure that matters. `users/vtjnash/tsa-tryheld-state` and
`users/vtjnash/tsa-tryheld-other` in twenty-six columns were both
`users/vtjnash/tsa-tryheld…`.

Plain text only, which is what these are: the colour is applied round the
column, never inside it, so there are no escapes here to carry across the cut.
"""
function amid(s::AbstractString, w::Int)
    w <= 0 && return ""
    awidth(s) <= w && return String(s)
    # Below three columns there is no room for a head, a mark and a tail, and
    # the arithmetic below would spend `w - 1` on each end and come back one
    # column too wide. Nothing useful can be said in two columns anyway.
    w == 1 && return "\u2026"
    w == 2 && return string(ahead(s, 1), "\u2026")
    keep = w - 1                       # what is left once the mark is paid for
    head = max(1, (2 * keep) ÷ 3)
    string(ahead(s, head), "\u2026", atail(s, keep - head))
end

"""Wrap to `w` display columns, preserving escapes and breaking at spaces.

Two things make this more than a chunking loop.

Style carries across a break: the active SGR codes are replayed at the start of
each continuation line, or a colour opened before the break would stop at it.
Escapes travel with the word they style, so that a word carried to the next line
takes its colour with it.

And a run wider than the pane has nowhere to break - a URL, a stack frame, a
type signature, all of which this is full of - so it falls back to breaking
mid-run rather than overflowing the pane.
"""
function awrap(s::AbstractString, w::Int)
    w <= 1 && return [s]
    out = String[]
    line, word = IOBuffer(), IOBuffer()   # committed; and the run since a space
    lw, ww = 0, 0                         # their display widths
    active = String[]                     # SGR codes in force right now
    wactive = String[]                    # ...and as of the start of `word`
    breakable = false                     # does `line` end at a space?
    emit!(codes) = begin
        push!(out, String(take!(line)))
        lw = 0
        isempty(codes) || write(line, join(codes))
    end
    commit!() = begin                     # fold the word into the line
        write(line, String(take!(word)))
        lw += ww; ww = 0
        wactive = copy(active)
    end
    carry!() = begin                      # move the word down to a new line
        before = copy(wactive)            # what was in force before the word
        emit!(before)                     # the word replays its own codes
        write(line, String(take!(word)))
        lw = ww; ww = 0
        wactive = copy(active)
        breakable = false
    end
    i = firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m !== nothing
            e = String(m.match)
            write(word, e)                # zero width, and belongs to the word
            if startswith(e, "\e[")
                e == "\e[0m" ? empty!(active) : push!(active, e)
            end
            i += ncodeunits(m.match)
            continue
        end
        c = s[i]
        cw = textwidth(c)
        # A loop rather than a branch: a word carried down can still be wider
        # than the pane on its own, and then has to be split anyway.
        while lw + ww + cw > w
            if breakable
                carry!()
            else
                commit!(); emit!(active)  # no space to break at; split the run
                breakable = false
            end
        end
        if isspace(c)
            commit!()
            write(line, c); lw += cw
            breakable = true
        else
            write(word, c); ww += cw
        end
        i = nextind(s, i)
    end
    write(line, String(take!(word)))
    push!(out, String(take!(line)))
    out
end
