namespace Index {
    string S_customFolderIndexingLocation = "";

    array<string> pendingFiles_FolderIndexing;
    array<string> pendingFiles_PrepareFiles;
    array<ReplayRecord> pendingFiles_AddToDatabase;

    bool isIndexing = false;
    bool f_isIndexing_FilePaths = false;
    bool p_isIndexing_PrepareFiles = false;
    bool d_isIndexing_AddToDatabase = false;

    int totalFileNumber = 0;
    int currentFileNumber = 0;

    string latestFile = "";
    string indexingMessage = "";
    string indexingMessageDebug = "";
    string currentIndexingPath = "";

    bool forceStopIndexing = false;


    uint prepareFilesIndex = 0;
    uint prepareFilesTotal = 0;
    uint addToDBIndex = 0;
    uint addToDBTotal = 0;
    float PHASE1_END   = 0.3f;
    float PHASE2_END   = 0.6f;
    // float PHASE3_END 0.6 -> 1.0

    void Stop_RecursiveSearch() {
        forceStopIndexing = true;
        isIndexing = false;
        totalFileNumber = 0;
        currentFileNumber = 0;
        latestFile = "";
        indexingMessage = "";
        currentIndexingPath = "";
        prepareFilesIndex = 0;
        prepareFilesTotal = 0;
        addToDBIndex = 0;
        addToDBTotal = 0;
    }

    void Start_RecursiveSearch(const string &in folderPath) {
        Stop_RecursiveSearch();
        log("Starting recursive search in folder: " + folderPath, LogLevel::Info);

        isIndexing = true;
        f_isIndexing_FilePaths = true;
        startnew(CoroutineFuncUserdataString(IndexFoldersAndSubfolders), folderPath);
        while (f_isIndexing_FilePaths && !forceStopIndexing) { yield(); }

        if (forceStopIndexing) {
            isIndexing = false;
            return;
        }

        p_isIndexing_PrepareFiles = true;
        prepareFilesIndex = 0;
        prepareFilesTotal = 0;
        startnew(PrepareFilesForAdditionToDatabase);
        while (p_isIndexing_PrepareFiles && !forceStopIndexing) { yield(); }

        if (forceStopIndexing) {
            isIndexing = false;
            return;
        }

        d_isIndexing_AddToDatabase = true;
        addToDBIndex = 0;
        addToDBTotal = 0;
        startnew(AddFilesToDatabase);
        while (d_isIndexing_AddToDatabase && !forceStopIndexing) { yield(); }

        isIndexing = false;
        indexingMessage = "Full addition to the database complete!";
        startnew(CoroutineFuncUserdataInt64(SetIndexingMessageToEmptyStringAfterDelay), 1000);
        log("Finished recursive search in folder: " + folderPath, LogLevel::Info);
    }

    bool IsIndexingInProgress() {
        return isIndexing;
    }

    float GetIndexingProgressFraction() {
        // PHASE 1
        // 
        if (f_isIndexing_FilePaths) { return 0.15f; }

        // PHASE 2
        if (p_isIndexing_PrepareFiles) {
            float phaseRatio = 0.0f;
            if (prepareFilesTotal > 0) {
                phaseRatio = float(prepareFilesIndex) / float(prepareFilesTotal);
            }
            return PHASE1_END + (PHASE2_END - PHASE1_END) * phaseRatio;
        }

        // PHASE 3
        if (d_isIndexing_AddToDatabase) {
            float phaseRatio = 0.0f;
            if (addToDBTotal > 0) {
                phaseRatio = float(addToDBIndex) / float(addToDBTotal);
            }
            return PHASE2_END + (1.0f - PHASE2_END) * phaseRatio;
        }

        return 1.0f;
    }

    // ---------------------------------------------------------
    // Phase 1: Index folders + subfolders, gather file paths
    // ---------------------------------------------------------
    array<string> dirsToProcess;
    int RECURSIVE_SEARCH_BATCH_SIZE = 100;
    int totalFoldersProcessed = 0;

    void IndexFoldersAndSubfolders(const string&in folderPath) {
        dirsToProcess.Resize(0);
        dirsToProcess.InsertLast(folderPath);
        totalFoldersProcessed = 0;

        while (f_isIndexing_FilePaths && dirsToProcess.Length > 0 && !forceStopIndexing) {
            string currentDir = dirsToProcess[dirsToProcess.Length - 1];
            dirsToProcess.RemoveAt(dirsToProcess.Length - 1);

            if (!IO::FolderExists(currentDir)) {
                log("Directory not found: " + currentDir, LogLevel::Warn);
                yield();
                continue;
            }
            string[]@ topLevel = IO::IndexFolder(currentDir, false);
            array<string> subfolders, files;
            for (uint i = 0; i < topLevel.Length; i++) {
                if (_IO::Directory::IsDirectory(topLevel[i])) {
                    subfolders.InsertLast(topLevel[i]);
                } else {
                    files.InsertLast(topLevel[i]);
                }
                if (i % RECURSIVE_SEARCH_BATCH_SIZE == 0) yield();
            }
            for (uint s = 0; s < subfolders.Length; s++) {
                dirsToProcess.InsertLast(subfolders[s]);
            }
            for (uint f = 0; f < files.Length && !forceStopIndexing; f++) {
                pendingFiles_FolderIndexing.InsertLast(files[f]);
                if (f % RECURSIVE_SEARCH_BATCH_SIZE == 0) yield();
            }
            totalFoldersProcessed++;
            yield();
        }
        f_isIndexing_FilePaths = false;
    }

    // ---------------------------------------------------------
    // Phase 2: Prepare files
    // ---------------------------------------------------------
    int PREPARE_FILES_BATCH_SIZE = 1;
    void PrepareFilesForAdditionToDatabase() {
        prepareFilesIndex = 0;
        prepareFilesTotal = pendingFiles_FolderIndexing.Length;
        for (uint i = 0; i < prepareFilesTotal && !forceStopIndexing; i++) {
            string filePath = pendingFiles_FolderIndexing[i];
            if (!filePath.ToLower().EndsWith(".replay.gbx")) continue;
            startnew(CoroutineFuncUserdataString(ProcessFileSafely), filePath);
            startnew(CoroutineFuncUserdataString(DeleteFileWith1000msDelay), IO::FromUserGameFolder(GetRelative_zzReplayPath() + "/tmp/") + Path::GetFileName(filePath));
            prepareFilesIndex++;
            if (i % PREPARE_FILES_BATCH_SIZE == 0) {
                yield();
            }
        }
        p_isIndexing_PrepareFiles = false;
    }

    void ProcessFileSafely(const string &in filePath) {
        indexingMessage = "Processing file: " + filePath;
        string parsePath = filePath;
        if (!parsePath.StartsWith(IO::FromUserGameFolder("Replays/"))) {
            string tmpFolder = IO::FromUserGameFolder(GetRelative_zzReplayPath() + "/tmp/");
            if (!IO::FolderExists(tmpFolder)) IO::CreateFolder(tmpFolder);
            string tempPath = tmpFolder + Path::GetFileName(filePath);
            if (IO::FileExists(tempPath)) {
                IO::Delete(tempPath);
            }
            _IO::File::CopyFileTo(filePath, tempPath);
            parsePath = tempPath;
            if (!IO::FileExists(parsePath)) {
                log("Failed to copy file: " + parsePath, LogLevel::Error);
                return;
            }
        }
        if (parsePath.StartsWith(IO::FromUserGameFolder(""))) {
            parsePath = parsePath.SubStr(IO::FromUserGameFolder("").Length);
        }
        CSystemFidFile@ fid = Fids::GetUser(parsePath);
        if (fid is null) return;
        CMwNod@ nod = Fids::Preload(fid);
        if (nod is null) return;
        CastFidToCorrectNod(nod, parsePath, filePath);
    }

    void CastFidToCorrectNod(CMwNod@ nod, const string &in parsePath, const string &in filePath) {
        CGameCtnReplayRecordInfo@ recordInfo = cast<CGameCtnReplayRecordInfo>(nod);
        if (recordInfo !is null) {
            ProcessFileWith_CGameCtnReplayRecordInfo(recordInfo);
            return;
        }
        CGameCtnReplayRecord@ record = cast<CGameCtnReplayRecord>(nod);
        if (record !is null) {
            ProcessFileWith_CGameCtnReplayRecord(record, parsePath, filePath);
            return;
        }
        CGameCtnGhost@ ghost = cast<CGameCtnGhost>(nod);
        if (ghost !is null) {
            ProcessFileWith_CGameCtnGhost(ghost, filePath);
            return;
        }
    }

    void ProcessFileWith_CGameCtnReplayRecord(CGameCtnReplayRecord@ record, const string &in parsePath, const string &in filePath) {
        if (record.Ghosts.Length == 0) return;
        if (record.Ghosts[0].RaceTime == 0xFFFFFFFF) return;
        if (record.Challenge.IdName.Length == 0) return;
        auto replay = ReplayRecord();
        replay.MapUid = record.Challenge.IdName;
        replay.PlayerLogin = record.Ghosts[0].GhostLogin;
        replay.PlayerNickname = record.Ghosts[0].GhostNickname;
        replay.FileName = Path::GetFileName(filePath);
        replay.Path = filePath;
        replay.BestTime = record.Ghosts[0].RaceTime;
        replay.FoundThrough = "Folder Indexing";
        replay.NodeType = Reflection::TypeOf(record).Name;
        replay.CalculateHash();
        pendingFiles_AddToDatabase.InsertLast(replay);
    }

    void ProcessFileWith_CGameCtnGhost(CGameCtnGhost@ ghost, const string &in filePath) {
        if (ghost.RaceTime == 0xFFFFFFFF) return;
        if (ghost.Validate_ChallengeUid.GetName().Length == 0) return;
        auto replay = ReplayRecord();
        replay.MapUid = ghost.Validate_ChallengeUid.GetName();
        replay.PlayerLogin = ghost.GhostLogin;
        replay.PlayerNickname = ghost.GhostNickname;
        replay.FileName = Path::GetFileName(filePath);
        replay.Path = filePath;
        replay.BestTime = ghost.RaceTime;
        replay.FoundThrough = "Folder Indexing";
        replay.NodeType = Reflection::TypeOf(ghost).Name;
        replay.CalculateHash();
        pendingFiles_AddToDatabase.InsertLast(replay);
    }

    void ProcessFileWith_CGameCtnReplayRecordInfo(CGameCtnReplayRecordInfo@ recordInfo) {
        if (recordInfo.BestTime == 0xFFFFFFFF) return;
        if (recordInfo.MapUid.Length == 0) return;
        auto replay = ReplayRecord();
        replay.MapUid = recordInfo.MapUid;
        replay.PlayerLogin = recordInfo.PlayerLogin;
        replay.PlayerNickname = recordInfo.PlayerNickname;
        replay.FileName = recordInfo.FileName;
        replay.Path = recordInfo.Path;
        replay.BestTime = recordInfo.BestTime;
        replay.FoundThrough = "Folder Indexing";
        replay.NodeType = Reflection::TypeOf(recordInfo).Name;
        replay.CalculateHash();
        pendingFiles_AddToDatabase.InsertLast(replay);
    }

    // ---------------------------------------------------------
    // Phase 3: Add to DB
    // ---------------------------------------------------------
    int ADD_FILES_TO_DATABASE_BATCH_SIZE = 100;

    void AddFilesToDatabase() {
        addToDBIndex = 0;
        addToDBTotal = pendingFiles_AddToDatabase.Length;
        for (uint i = 0; i < pendingFiles_AddToDatabase.Length && !forceStopIndexing; i++) {
            ReplayRecord@ replay = pendingFiles_AddToDatabase[i];
            AddFileToDatabaseSafely(replay);
            // ERR : Can't create delegate for types that do not support handles
            // startnew(CoroutineFuncUserdata(AddFileToDatabaseSafely), replay);
            addToDBIndex++;
            if (i % ADD_FILES_TO_DATABASE_BATCH_SIZE == 0) {
                yield();
            }
        }
        d_isIndexing_AddToDatabase = false;
    }

    void AddFileToDatabaseSafely(ReplayRecord@ replay) {
        if (!replayRecords.Exists(replay.MapUid)) {
            array<ReplayRecord@> records;
            replayRecords[replay.MapUid] = records;
        }
        auto records = cast<array<ReplayRecord@>>(replayRecords[replay.MapUid]);
        records.InsertLast(replay);
        AddReplayToDatabse(replay);
        currentFileNumber++;
    }

    // ---------------------------------------------------------

    void SetIndexingMessageToEmptyStringAfterDelay(int64 delay) {
        sleep(delay);
        indexingMessage = "";
    }
}
