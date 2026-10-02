# The manual is the README, so that there is one of it, and the rest is every
# docstring: what a host imports, and what the iframe is made of.
#
#     julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#     julia --project=docs docs/make.jl
#
# with `TermInput.jl` checked out beside this one, as for the tests.
#
# `build/` is the site; `deploydocs` publishes it from CI and does nothing
# anywhere else.
using Documenter, TermIFrame

const ROOT = dirname(@__DIR__)

# A link to a heading is GitHub's lowercased slug in the README and the heading
# itself in Documenter, so the one is rewritten into the other on the way in.
function readme_page(readme, page)
    md = read(readme, String)
    slug(h) = replace(lowercase(h), r"[^\w\- ]" => "", ' ' => '-')
    heads = Dict(slug(m[1]) => m[1] for m in eachmatch(r"(?m)^#+ +(.+?) *$", md))
    md = replace(md, r"\]\(#([\w-]+)\)" => s -> begin
        h = get(heads, match(r"#([\w-]+)", s)[1], nothing)
        h === nothing ? s : string("](@ref \"", h, "\")")
    end)
    write(page, md)
end
readme_page(joinpath(ROOT, "README.md"), joinpath(@__DIR__, "src", "index.md"))

makedocs(;
    sitename = "TermIFrame.jl",
    repo = Remotes.GitHub("vtjnash", "TermIFrame.jl"),
    modules = [TermIFrame],
    format = Documenter.HTML(; prettyurls = get(ENV, "CI", nothing) == "true",
                             edit_link = "main"),
    pages = ["Manual" => "index.md", "API" => "api.md", "Internals" => "internals.md"],
)

deploydocs(; repo = "github.com/vtjnash/TermIFrame.jl.git", devbranch = "main",
           push_preview = false)
