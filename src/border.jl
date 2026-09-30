# The box drawn round an embedded screen.
#
# The characters are `TermInput`'s box, `CHROME[].box` unless a box is passed,
# so an iframe beside a composer, a dialog or a table a host drew is bordered
# the same way - a host sets the box where it sets the weights, and both follow.
#
# The rows are laid out against real display widths, since a captured screen
# is a child program's raw SGR and OSC 8, and a measure that counted those as
# characters - Term's `Panel`, which measures markup - wraps content that fits
# and then elides its own tail. `TermInput`'s `awidth`, `afit` and `apad` are
# that measure, and a text field needs it for the same reason.

"""
    bordered(lines, w, h, title; focused = true, box = boxstyle(),
             chrome = CHROME[], gutter = String[]) -> Vector{String}

Draw one bordered box, every row exactly `w` display columns and exactly `h`
rows of them. `lines` are the contents, already ANSI; anything past `h - 2` of
them is dropped and anything short is blank.

`focused` is bold against dim, which is the one thing a host with several boxes
on screen has to be able to say without spending a row on it. `box` and
`chrome` are `TermInput`'s: the box the theme asked for and the weights it is
painted in, so that an iframe and a composer on the same screen cannot disagree
about either.

`gutter` is a mark per line, drawn *over* the left border and its pad - two
columns - on the rows that have one; an empty string, or none, is the border
as usual. It is for a mark about a row rather than in it: a comment hanging off
a line of a diff is the case, and at the end of the row it was after the text,
where the eye is not, while a mark standing in the frame is where a margin note
goes. Padded to the two columns, and one wider than that is not drawn at all:
two columns cut is an ellipsis, which says nothing.
"""
function bordered(lines::Vector{String}, w::Int, h::Int, title::AbstractString;
                  focused::Bool = true, box = boxstyle(), chrome = CHROME[],
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
