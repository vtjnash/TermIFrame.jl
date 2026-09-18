# The box drawn round an embedded screen.
#
# This is where the package is a Term plugin rather than a tmux wrapper: the
# characters come from Term's own box vocabulary and default to the box the
# current theme uses, so an iframe sitting beside a `Term.Panel` is bordered
# the same way it is - change `TERM_THEME[].box` and both follow.
#
# What does not come from Term is the *measuring*. `Panel` measures markup, and
# a captured screen is not markup: it is a child program's raw SGR and OSC 8,
# which `Panel` counts as characters. Content that fits is wrapped and the panel
# then elides its own tail. So the rows are laid out against real display widths
# - `TermInput`'s `awidth`, `afit` and `apad`, which a text field needs for the
# same reason - and Term supplies the glyphs.

"""The box style to draw with, following Term's theme unless told otherwise.

`TermInput.boxstyle`, so that an iframe and a composer drawn on the same screen
cannot disagree about which box the theme asked for.
"""
iframe_box_style() = boxstyle()

"""
    bordered(lines, w, h, title, focused; box, chrome, gutter) -> Vector{String}

Draw one bordered box, every row exactly `w` display columns and exactly `h`
rows of them. `lines` are the contents, already ANSI; anything past `h - 2` of
them is dropped and anything short is blank.

`focused` is bold against dim, which is the one thing a host with several boxes
on screen has to be able to say without spending a row on it.

`gutter` is a mark per line, drawn *over* the left border and its pad - two
columns - on the rows that have one; an empty string, or none, is the border
as usual. It is for a mark about a row rather than in it: a comment hanging off
a line of a diff is the case, and at the end of the row it was after the text,
where the eye is not, while a mark standing in the frame is where a margin note
goes. Padded to the two columns, and one wider than that is not drawn at all:
two columns cut is an ellipsis, which says nothing.
"""
function bordered(lines::Vector{String}, w::Int, h::Int, title::AbstractString,
                  focused::Bool; box = iframe_box_style(), chrome = CHROME[],
                  gutter::AbstractVector{<:AbstractString} = String[])
    # Which of the two weights a border is drawn in *is* the answer to "where
    # do my keys go", so it is the one thing here that is not decoration. The
    # weights themselves are the host's - `TermInput.CHROME`, which is also
    # where the widgets on the other side of this split get theirs.
    bw = focused ? chrome.strong : chrome.quiet
    R = chrome.reset
    inner = w - 4
    t = afit(String(title), max(0, inner - 4))
    tl, tm, tr = box.top.left, box.top.mid, box.top.right
    ml, mr = box.mid.left, box.mid.right
    bl, bm, br = box.bottom.left, box.bottom.mid, box.bottom.right
    # `tl tm " "` + title + `" "` + bar + `tr` must total w, so the filler is
    # w - 5 - |title|.
    bar = string(tm)^max(0, w - 5 - awidth(t))
    out = [string(bw, tl, tm, " ", R, bw, t, R, bw, " ", bar, tr, R)]
    for i in 1:(h - 2)
        c = i <= length(lines) ? lines[i] : ""
        g = i <= length(gutter) ? gutter[i] : ""
        left = (isempty(g) || awidth(g) > 2) ? string(bw, ml, R, " ") :
               string(apad(g, 2), R)
        push!(out, string(left, apad(afit(c, inner), inner), " ", bw, mr, R))
    end
    push!(out, string(bw, bl, string(bm)^max(0, w - 2), br, R))
    out
end
