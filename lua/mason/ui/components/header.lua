local Ui = require "mason-core.ui"
local p = require "mason.ui.palette"

---@param state InstallerUiState
return function(state)
    return Ui.CascadingStyleNode({ "CENTERED" }, {
        Ui.HlTextNode {
            Ui.When(state.view.is_showing_help, {
                p.header_secondary(" " .. state.header.title_prefix .. " mason.nvim "),
                p.none((" "):rep(#state.header.title_prefix + 1)),
            }, {
                p.header " mason.nvim ",
            }),
            Ui.When(
                state.view.is_showing_help,
                { p.none "        press ", p.highlight_secondary "?", p.none " for package list" },
                { p.none "press ", p.highlight "?", p.none " for help" }
            ),
            { p.WarningMsg " alpha branch is no longer active, switch to default branch (main)", },
            { p.Comment "https://github.com/williamboman/mason.nvim" },
        },
    })
end
