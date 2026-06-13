// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#pragma once
#include <QWidget>
#include <QString>
#include "include/desgrana_bridge.h"
#include <map>
#include <utility>
#include <vector>

class QDragEnterEvent;
class QDragLeaveEvent;
class QDropEvent;
class QFrame;
class QLabel;
class QLineEdit;
class QProgressBar;
class QPushButton;
class QScrollArea;

class DesgranaWindow : public QWidget {
    Q_OBJECT
public:
    explicit DesgranaWindow(QWidget *parent = nullptr);

protected:
    void dragEnterEvent(QDragEnterEvent *) override;
    void dragLeaveEvent(QDragLeaveEvent *) override;
    void dropEvent(QDropEvent *) override;
    bool eventFilter(QObject *obj, QEvent *event) override;

private slots:
    void browseOutput();
    void browseSession();
    void startSplit();
    void onProgress(int take, int total, double fraction);
    void onSplitDone(int silentSkipped, int keptMono, int keptStereo);
    void onSplitError(const QString &msg);
    void onSessionNameChanged(const QString &name);
private:
    void buildIdlePage();
    void buildReadyPage();
    void buildSplittingPage();
    void buildDonePage();

    void loadSession(const QString &path);
    void loadSnap(const QString &snapPath);
    void switchToPage(int index);
    void showIdle(const QString &error = {});
    void showReady();
    void showSplitting();
    void showDone(int keptMono, int keptStereo, int silentSkipped);
    void populateChannelList();
    void handleChannelRowClick(QWidget *row);
    void updateOutputPath();
    void checkOutputExists();
    void checkForUpdate();
    void applyDynamicStyles();
    void changeEvent(QEvent *e) override;

    // State machine (pages shown/hidden directly — QStackedWidget always sizes to
    // the largest page and cannot shrink when switching to a smaller one)
    int m_currentPage = -1;

    // Idle page
    QWidget *m_idlePage;
    QFrame  *m_dropZoneFrame;
    QLabel  *m_idleErrorLabel;

    // Ready page
    QWidget     *m_readyPage;
    QLineEdit   *m_sessionNameEdit;
    QLabel      *m_snapHintLabel = nullptr;
    QScrollArea *m_channelScroll;
    QWidget     *m_channelContainer = nullptr;
    std::map<int, QLabel*> m_badgeLabels;
    std::map<int, QLabel*> m_chnumLabels;
    QLineEdit   *m_outputEdit;
    QLabel      *m_outputWarningLabel;
    QLabel      *m_lowDiskWarningLabel = nullptr;
    QPushButton *m_browseBtn;
    QPushButton *m_splitBtn;

    // Splitting page
    QWidget      *m_splittingPage;
    QProgressBar *m_progress;
    QLabel       *m_splittingLabel;

    // Done page
    QWidget     *m_donePage;
    QLabel      *m_summaryLabel;
    QLabel      *m_silentLabel;
    QPushButton *m_openDirBtn;
    int          m_silentSkipped = 0;

    // Persistent update notification
    QLabel *m_updateLabel;

    // Session data
    QString  m_sessionPath;
    int32_t  m_snapFound = 0;
    QString m_sessionName;
    QString m_lastOutputPath;
    int     m_channels  = 0;
    double  m_duration  = 0;
    qint64  m_expectedOutputBytes = 0;  // ~size the extraction will write
    bool    m_useShortNames = true;

    static constexpr int kSnapCap = 64;
    int32_t m_pairLefts[kSnapCap]              = {};
    int32_t m_pairRights[kSnapCap]             = {};
    int32_t m_pairCount                        = 0;
    int32_t m_chKeys[kSnapCap]                 = {};
    char    m_chNames[kSnapCap][DESGRANA_CH_NAME_MAX] = {};
    int32_t m_chCount                          = 0;
    std::vector<std::pair<int,int>> m_effectivePairs;
    std::map<int, QWidget *>        m_rowWidgets;

};
