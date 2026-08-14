' DeepSeek Harness 启动台 - Windows 无黑窗启动（双击本文件）
Set sh = CreateObject("WScript.Shell")
port = "4899"
url = "http://127.0.0.1:" & port & "/"
Set http = CreateObject("MSXML2.XMLHTTP")
On Error Resume Next
http.Open "GET", url, False
http.setRequestHeader "Connection", "close"
http.Send ""
If Err.Number = 0 And http.Status = 200 Then
  sh.Run """" & url & """", 1, False
  WScript.Quit
End If
On Error GoTo 0
sh.Run "cmd /c node """ & Replace(WScript.ScriptFullName, WScript.ScriptName, "") & "server.js""", 0, False
WScript.Sleep 2500
sh.Run """" & url & """", 1, False
