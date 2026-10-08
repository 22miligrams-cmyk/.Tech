//@ pragma UseQApplication
import QtQuick
import Quickshell
import "bar"
import "panels"
import "notifications"
import "settings"
import "common"

ShellRoot {
    id: root

    Logic {
        id: logic
    }

    Notify {
        id: notify
        logic: logic
    }

    Visual {
        logic: logic
        notify: notify
    }

    Component.onCompleted: {
        const laun = Quickshell.shellPath("launchers/laun.qml")
        Quickshell.execDetached(["sh", "-c",
            'quickshell ipc -p "$1" show >/dev/null 2>&1 || quickshell -d -p "$1"', "sh", laun])

        const wall = Quickshell.shellPath("launchers/wall.qml")
        Quickshell.execDetached(["sh", "-c",
            'quickshell ipc -p "$1" show >/dev/null 2>&1 || quickshell -d -p "$1"', "sh", wall])
    }
}
