namespace MapTracker {
    string oldMapUid = "";

    [Setting category="General" name="Load Ghost on Map Enter"]
    bool enableGhosts = true;

    void MapMonitor() {
        while (true) {    
            sleep(273);

            if (!enableGhosts) continue;

            if (HasMapChanged()) {
                AllowCheck::InitializeAllowCheck();


                uint timeout = 10000;
                uint startTime = Time::Now;
                while (!AllowCheck::ConditionCheckMet()) {
                    if (Time::Now - startTime > timeout) { NotifyWarn("Condition check timed out ("+timeout+" ms was given), assuming invalid state."); break; }
                    yield();
                }

                PBManager::Initialize(GetApp());
                PBManager::LoadPBFromIndex();
            }

            if (HasMapChanged()) oldMapUid = get_CurrentMapUID();
        }
    }

    bool HasMapChanged() {
        return oldMapUid != get_CurrentMapUID();
    }
}

string get_CurrentMapUID() {
    if (_Game::IsMapLoaded()) {
        CTrackMania@ app = cast<CTrackMania>(GetApp());
        if (app is null) return "";
        CGameCtnChallenge@ map = app.RootMap;
        if (map is null) return "";
        return map.MapInfo.MapUid;
    }
    return "";
}

string get_CurrentMapName() {
    if (_Game::IsMapLoaded()) {
        CTrackMania@ app = cast<CTrackMania>(GetApp());
        if (app is null) return "";
        CGameCtnChallenge@ map = app.RootMap;
        if (map is null) return "";
        return map.MapInfo.Name;
    }
    return "";
}
