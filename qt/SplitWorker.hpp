// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#pragma once
#include <QObject>
#include <QString>
#include <string>
#include <vector>

class SplitWorker : public QObject {
    Q_OBJECT
public:
    struct Params {
        QString sessionPath;
        QString outputPath;
        QString prefix;
        std::vector<int32_t>     pairLefts;
        std::vector<int32_t>     pairRights;
        std::vector<int32_t>     chKeys;
        std::vector<std::string> chNames;
    };

    explicit SplitWorker(Params p, QObject *parent = nullptr);

public slots:
    void run();

signals:
    void progress(int take, int total);
    void done(int silentSkipped, int keptMono, int keptStereo);
    void error(const QString &msg);

private:
    Params m_params;
};
