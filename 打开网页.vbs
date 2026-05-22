' 无黑窗口启动（双击本文件）
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

args = ""
For i = 0 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If InStr(a, " ") > 0 Then
        args = args & " """ & a & """"
    Else
        args = args & " " & a
    End If
Next

cmd = """" & ps & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & dir & "\Open-EdgeWeb.ps1""" & args
shell.Run cmd, 0, False
