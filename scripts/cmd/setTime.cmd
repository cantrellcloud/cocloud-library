@echo off
cls
net time \\cotpa-dc01.cantrelloffice.cloud
net time \\cotpa-dc02.cantrelloffice.cloud
net time \\cotpa-dc03.cantrelloffice.cloud /set /yes
net time \\copine-dc01.cantrelloffice.cloud
net time \\copine-dc02.cantrelloffice.cloud