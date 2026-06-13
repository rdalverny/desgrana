// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#include <QApplication>
#include "DesgranaWindow.hpp"

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setApplicationName("Desgrana");
    app.setOrganizationName("elephathom");

    DesgranaWindow win;
    win.show();
    return app.exec();
}
