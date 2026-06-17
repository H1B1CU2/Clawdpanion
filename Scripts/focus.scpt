-- Focus the Terminal.app window/tab whose tty matches argv[1].
on run argv
	if (count of argv) < 1 then return "no-tty"
	set theTTY to item 1 of argv
	tell application "Terminal"
		activate
		repeat with w in windows
			repeat with t in tabs of w
				try
					if (tty of t) is theTTY then
						set selected of t to true
						set frontmost of w to true
						return "ok"
					end if
				end try
			end repeat
		end repeat
	end tell
	return "notfound"
end run
