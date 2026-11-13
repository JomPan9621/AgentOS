Set sh = CreateObject("WScript.Shell")
rc = sh.Run("cmd.exe /c ""__WATCH_TASK_CMD__""", 0, True)
WScript.Quit rc
