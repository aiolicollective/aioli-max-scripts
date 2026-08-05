-- =========================================================================
--  aioli-sunpos  --  3ds Max launcher / installer
--  ------------------------------------------------------------------------
--  USAGE
--    Drag THIS file into a 3ds Max window (drag & drop).
--      -> the panel opens straight away;
--      -> a macro "sunpos" is registered under the "aioli" category.
--
--    For a permanent button (once and for all):
--      Customize > Customize User Interface... > Toolbars tab,
--      Category = "aioli", drag "sunpos" onto a toolbar.
--
--  WHERE DOES THE MACRO GO?  Not into this folder: 3ds Max writes it into ITS
--  own user files, at
--    %LOCALAPPDATA%\Autodesk\3dsMax\<version>\ENU\usermacros\aioli_sunpos.mcr
--  That is what makes the toolbar button survive restarts -- Max re-reads that
--  folder on startup. To uninstall, delete that .mcr.
--  Without a macro MaxScript cannot build a toolbar button at all: that is the
--  one and only reason this file exists.
--
--  The .py path is baked into the macro at drag & drop time, so if you move the
--  sunpos folder, drag this file in once more.
--
--  License: MIT -- (c) aioli collective
-- =========================================================================

(
    local pyFile = (getFilenamePath (getSourceFileName())) + "sunpos_max.py"

    if not doesFileExist pyFile then
    (
        messageBox ("sunpos_max.py was not found next to this script.\n\n" \
                    + "Expected here:\n" + pyFile + "\n\n" \
                    + "Keep aioli-sunpos.ms in the same folder as sunpos_max.py.") \
                   title:"aioli-sunpos"
    )
    else
    (
        -- The macro is built with the path hard-coded: no side-car config file
        -- to keep in sync.
        local src = ""
        src += "macroScript aioli_sunpos category:\"aioli\" buttonText:\"sunpos\" "
        src += "toolTip:\"aioli-sunpos - place the sun from a GPS point / date / time\"\n"
        src += "(\n"
        src += "    on execute do\n"
        src += "    (\n"
        src += "        local py = @\"" + pyFile + "\"\n"
        src += "        if doesFileExist py then\n"
        src += "        (\n"
        src += "            -- ExecuteFile re-reads the file on every click, so\n"
        src += "            -- edits to the .py apply without restarting Max.\n"
        src += "            python.ExecuteFile py\n"
        src += "        )\n"
        src += "        else\n"
        src += "        (\n"
        src += "            messageBox (\"Script not found:\\n\" + py + \"\\n\\n\" + \\\n"
        src += "                        \"Did the sunpos folder move? \" + \\\n"
        src += "                        \"Drag aioli-sunpos.ms into 3ds Max again.\") \\\n"
        src += "                       title:\"aioli-sunpos\"\n"
        src += "        )\n"
        src += "    )\n"
        src += ")\n"
        execute src

        format "[aioli-sunpos] macro \"sunpos\" registered (category \"aioli\")\n"
        format "[aioli-sunpos] script : %\n" pyFile
        format "[aioli-sunpos] button : Customize > Customize User Interface > Toolbars > Category \"aioli\"\n"

        python.ExecuteFile pyFile
    )
)
