#!/usr/bin/env python3
import subprocess
import json
import sys

applescript = '''
tell application "System Events"
    if not (exists (process "Antigravity")) then
        return "PROCESS_NOT_FOUND"
    end if
    tell process "Antigravity"
        set uiReport to {}
        
        -- Windows & Sheets
        repeat with w in windows
            set wTitle to name of w
            set wRole to role of w
            set wSubrole to subrole of w
            
            set sheetList to {}
            repeat with s in sheets of w
                set sTitle to name of s
                set sRole to role of s
                set sheetList to sheetList & {title:sTitle, role:sRole}
            end repeat
            
            set popoverList to {}
            repeat with p in popovers of w
                set pTitle to name of p
                set pRole to role of p
                set popoverList to popoverList & {title:pTitle, role:pRole}
            end repeat

            set dialogList to {}
            repeat with d in UI elements of w
                set dRole to role of d
                if dRole contains "Dialog" or dRole contains "Sheet" or dRole contains "Window" then
                    set dialogList to dialogList & {role:dRole, description:description of d}
                end if
            end repeat

            set uiReport to uiReport & {windowTitle:wTitle, windowRole:wRole, windowSubrole:wSubrole, sheets:sheetList, popovers:popoverList, dialogs:dialogList}
        end repeat
        
        return uiReport
    end tell
end tell
'''

def main():
    res = subprocess.run(["osascript", "-e", applescript], capture_output=True, text=True)
    print("STDOUT:")
    print(res.stdout)
    print("STDERR:")
    print(res.stderr)

if __name__ == "__main__":
    main()
