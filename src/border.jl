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
    bordered(lines, w, h, title, focused; box) -> Vector{String}

Draw one bordered box, every row exactly `w` display columns and exactly `h`
rows of them. `lines` are the contents, already ANSI; anything past `h - 2` of
them is dropped and anything short is blank.

`focused` is bold against dim, which is the one thing a host with several boxes
on screen has to be able to say without spending a row on it.
"""
function bordered(lines::Vector{String}, w::Int, h::Int, title::AbstractString,
                  focused::Bool; box = iframe_box_style())
    bw = focused ? "\e[1m" : "\e[2m"
    R = "\e[0m"
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
        push!(out, string(bw, ml, R, " ", apad(afit(c, inner), inner), " ", bw, mr, R))
    end
    push!(out, string(bw, bl, string(bm)^max(0, w - 2), br, R))
    out
end
