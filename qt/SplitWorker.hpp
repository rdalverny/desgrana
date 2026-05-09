// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#pragma once
#include <QObject>
#include <QString>
#include "include/desgrana_bridge.h"
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

    explicit SplitWorker(Params p, QObject *parent = nullptr)
        : QObject(parent), m_params(std::move(p)) {}

public slots:
    void run() {
        char err[512] = {};
        std::vector<const char *> chVals;
        for (const auto &n : m_params.chNames) chVals.push_back(n.c_str());
        int rc = desgrana_split(
            m_params.sessionPath.toUtf8().constData(),
            m_params.outputPath.toUtf8().constData(),
            m_params.prefix.isEmpty() ? nullptr : m_params.prefix.toUtf8().constData(),
            m_params.pairLefts.empty()  ? nullptr : m_params.pairLefts.data(),
            m_params.pairRights.empty() ? nullptr : m_params.pairRights.data(),
            static_cast<int32_t>(m_params.pairLefts.size()),
            m_params.chKeys.empty() ? nullptr : m_params.chKeys.data(),
            chVals.empty()          ? nullptr : chVals.data(),
            static_cast<int32_t>(chVals.size()),
            [](int32_t take, int32_t total, void *ud) {
                auto *w = static_cast<SplitWorker *>(ud);
                emit w->progress(take, total);
            },
            this,
            err, sizeof(err)
        );
        if (rc == 0)
            emit done();
        else
            emit error(QString::fromUtf8(err));
    }

signals:
    void progress(int take, int total);
    void done();
    void error(const QString &msg);

private:
    Params m_params;
};
