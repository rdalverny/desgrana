// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#pragma once
#include <QWidget>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QProgressBar>
#include <QFrame>

class SplitWorker;

class DesgranaWindow : public QWidget {
    Q_OBJECT
public:
    explicit DesgranaWindow(QWidget *parent = nullptr);

protected:
    void dragEnterEvent(QDragEnterEvent *) override;
    void dropEvent(QDropEvent *) override;

private slots:
    void browseOutput();
    void startSplit();
    void onProgress(int take, int total);
    void onDone();
    void onError(const QString &msg);

private:
    void loadSession(const QString &path);
    void setReady(bool ready);

    QString     m_sessionPath;
    int         m_channels = 0;
    double      m_duration = 0;

    QLabel      *m_dropLabel;
    QFrame      *m_dropZone;
    QLabel      *m_infoLabel;
    QLineEdit   *m_outputEdit;
    QPushButton *m_browseBtn;
    QPushButton *m_splitBtn;
    QProgressBar *m_progress;
    QLabel      *m_statusLabel;
};
