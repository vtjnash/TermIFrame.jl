# The box drawn round an embedded screen.
#
# The characters are `TermInput`'s box, `CHROME[].box` unless a box is passed,
# so an iframe beside a composer, a dialog or a table a host drew is bordered
# the same way - a host sets the box where it sets the faces, and both follow.
#
# A row is `TermInput`'s: faces over text, measured by its text. A captured
# screen's row is not parsed into one - it is the child's own escapes, as the
# multiplexer gave them - but carried inside one as a verbatim piece as wide as
# the pane, which nothing here measures, cuts or restyles.

"""
    bordered(lines, w, h, title; focused = true, box = boxstyle(),
             chrome = CHROME[], gutter = String[]) -> Vector{Row}

Draw one bordered box, every row exactly `w` display columns and exactly `h`
rows of them. `lines` are the contents, each a string or a `TermInput.Row` -
faces, and a verbatim piece where a line is a screen's; anything past `h - 2`
of them is dropped and anything short is blank. A line is fitted to the inside
by `TermInput`'s `rowfit` and `rowpad`, which take a verbatim piece at the
width it says and never cut into one.

`focused` is strong against quiet, which is the one thing a host with several
boxes on screen has to be able to say without spending a row on it. `box` and
`chrome` are `TermInput`'s: the box the theme asked for and the faces it is
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
function bordered(lines::AbstractVector{<:AbstractString}, w::Int, h::Int,
                  title::AbstractString; focused::Bool = true, box = boxstyle(),
                  chrome = CHROME[], gutter::AbstractVector{<:AbstractString} = String[])
    # Which of the two faces a border is drawn in *is* the answer to "where do
    # my keys go", so it is the one thing here that is not decoration. The
    # faces themselves are the host's - `TermInput.CHROME`, which is also where
    # the widgets on the other side of this split get theirs.
    bw = focused ? chrome.strong : chrome.quiet
    inner = w - 4
    t = rowfit(title, max(0, inner - 4))
    tl, tm, tr = box.top.left, box.top.mid, box.top.right
    ml, mr = box.mid.left, box.mid.right
    bl, bm, br = box.bottom.left, box.bottom.mid, box.bottom.right
    # `tl tm " "` + title + `" "` + bar + `tr` must total w, so the filler is
    # w - 5 - |title|.
    bar = string(tm)^max(0, w - 5 - rowwidth(t))
    out = Row[faced(rowcat(string(tl, tm, " "), t, string(" ", bar, tr)), bw)]
    for i in 1:(h - 2)
        c = i <= length(lines) ? lines[i] : ""
        g = i <= length(gutter) ? gutter[i] : ""
        left = (isempty(g) || rowwidth(g) > 2) ? rowcat(faced(string(ml), bw), " ") :
               rowpad(g, 2)
        push!(out, rowcat(left, rowpad(rowfit(c, inner), inner), " ", faced(string(mr), bw)))
    end
    push!(out, faced(string(bl, string(bm)^max(0, w - 2), br), bw))
    out
end
