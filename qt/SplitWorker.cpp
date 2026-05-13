// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#include "SplitWorker.hpp"
#include "include/desgrana_bridge.h"

SplitWorker::SplitWorker(Params p, QObject *parent)
    : QObject(parent), m_params(std::move(p)) {}

void SplitWorker::run() {
    char err[512] = {};
    int32_t silentSkipped = 0, keptMono = 0, keptStereo = 0;
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
        [](int32_t take, int32_t total, double fraction, void *ud) {
            auto *w = static_cast<SplitWorker *>(ud);
            emit w->progress(take, total, fraction);
        },
        this,
        &silentSkipped,
        &keptMono,
        &keptStereo,
        err, sizeof(err)
    );
    if (rc == 0)
        emit done(static_cast<int>(silentSkipped),
                  static_cast<int>(keptMono),
                  static_cast<int>(keptStereo));
    else
        emit error(QString::fromUtf8(err));
}
