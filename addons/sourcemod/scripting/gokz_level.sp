#pragma semicolon 1
#pragma newdecls required
#include <sdktools>
#include <sdkhooks>
#include <SteamWorks>
#include <smjansson>
#include <colorlib>
#include <gokz/core>

public Plugin myinfo =
{
    name = "KZ Skill Level",
    description = "Show KZ skill icon on scoreboard & allow !rating check",
    author = "Cinyan10",
    version = "1.0.1"
};

enum struct Player
{
    int iUserID;
    int iSkillLevel;
    float fSkillScore;
    bool bLoad;
}

Player g_Players[MAXPLAYERS + 1];
char g_sModeParamNames[3][16] = { "kz_vanilla", "kz_simple", "kz_timer" };
int m_nPersonaDataPublicLevel;
bool g_UsesGokz = false;
int g_LastRetryTime[MAXPLAYERS + 1];
const int RETRY_INTERVAL = 15;

public void OnPluginStart()
{
    g_UsesGokz = LibraryExists("gokz-core");
    m_nPersonaDataPublicLevel = FindSendPropInfo("CCSPlayerResource", "m_nPersonaDataPublicLevel");

    RegConsoleCmd("sm_rating", Command_ShowRating);

    for (int i = 1; i <= MaxClients; ++i)
    {
        if (IsClientAuthorized(i) && !IsFakeClient(i))
        {
            OnClientPutInServer(i);
        }
    }
}

public void OnMapStart()
{
    char path[PLATFORM_MAX_PATH];
    for (int i = 0; i < 10; i++)
    {
        Format(path, sizeof(path), "materials/panorama/images/icons/xp/level%i.png", 5001 + i);
        AddFileToDownloadsTable(path);
    }

    SDKHook(GetPlayerResourceEntity(), SDKHook_ThinkPost, Hook_OnThinkPost);
}

public void OnClientPutInServer(int client)
{
    int userID = GetClientUserId(client);
    if (g_Players[client].iUserID != userID)
    {
        g_Players[client].iUserID = userID;
        g_Players[client].iSkillLevel = 0;
        g_Players[client].fSkillScore = 0.0;
        g_Players[client].bLoad = false;
    }

    if (g_Players[client].bLoad || IsFakeClient(client))
        return;

    int mode = g_UsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
    if (mode < 0 || mode > 2)
        mode = 2;

    char steamID[64];
    GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));

    char url[256];
    Format(url, sizeof(url), "https://api.gokz.top/leaderboard/%s", steamID);
    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (hRequest == INVALID_HANDLE)
        return;

    SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, 20);
    SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "mode", g_sModeParamNames[mode]);
    SteamWorks_SetHTTPRequestContextValue(hRequest, GetClientUserId(client) + mode * 10000);
    SteamWorks_SetHTTPCallbacks(hRequest, HTTPRequestComplete);
    SteamWorks_SendHTTPRequest(hRequest);

    LogMessage("[KZSkillLevel] [%N] Sent HTTP request to %s", client, url);

    g_LastRetryTime[client] = GetTime();
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
    if (StrEqual(option, gC_CoreOptionNames[Option_Mode]))
    {
        // reload when player change mode
        g_Players[client].iSkillLevel = 0;
        g_Players[client].fSkillScore = 0.0;
        g_Players[client].bLoad = false;

        int ent = GetPlayerResourceEntity();
        if (ent != -1)
        {
            SetEntData(ent, m_nPersonaDataPublicLevel + client * 4, 0, 4, true);
        }

        OnClientPutInServer(client);
    }
}

void HTTPRequestComplete(Handle hRequest, bool bFailure, bool bSuccess, EHTTPStatusCode eStatusCode, any ctx)
{
    int contextVal = ctx;
    int userID = contextVal % 10000;
    // int reqMode = contextVal / 10000;
    int client = GetClientOfUserId(userID);

    if (client && (eStatusCode == k_EHTTPStatusCode200OK || eStatusCode == k_EHTTPStatusCode404NotFound))
    {
        if (eStatusCode == k_EHTTPStatusCode200OK)
        {
            SteamWorks_GetHTTPResponseBodyCallback(hRequest, HTTPResponseData, ctx);
        }
        else
        {
            g_Players[client].bLoad = true;
        }
    }

    delete hRequest;
}

void HTTPResponseData(const char[] body, any ctx)
{
    int contextVal = ctx;
    int userID = contextVal % 10000;
    int reqMode = contextVal / 10000;
    int client = GetClientOfUserId(userID);

    if (!client || (g_UsesGokz && reqMode != GOKZ_GetCoreOption(client, Option_Mode)))
        return;

    Handle hJson = json_load(body);
    if (hJson != INVALID_HANDLE)
    {
        float pts = json_object_get_float(hJson, "pts_skill");
        g_Players[client].fSkillScore = pts;
        g_Players[client].iSkillLevel = RoundToFloor(pts);
        if (g_Players[client].iSkillLevel > 10)
            g_Players[client].iSkillLevel = 10;
        else if (g_Players[client].iSkillLevel < 1)
            g_Players[client].iSkillLevel = 0;
 
        g_Players[client].bLoad = true;
        CloseHandle(hJson);
    }
}

void Hook_OnThinkPost(int ent)
{
    int now = GetTime();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        int level = g_Players[i].iSkillLevel;
        if (!g_Players[i].bLoad)
        {
            level = 1;  // default level before data is loaded
        }

        if (level > 0)
        {
            SetEntData(ent, m_nPersonaDataPublicLevel + i * 4, 5000 + level, 4, true);
        }

        if (!g_Players[i].bLoad && (now - g_LastRetryTime[i]) >= RETRY_INTERVAL)
        {
            OnClientPutInServer(i);
        }
    }
}


public Action Command_ShowRating(int client, int args)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Handled;

    LogMessage("[KZSkillLevel] [%N] ran !rating - Loaded: %b", client, g_Players[client].bLoad);

    if (g_Players[client].bLoad)
    {
        CPrintToChat(client, "{gold}GOKZ.TOP {grey}| {default}Your Rating: {green}%.2f{default} {grey}| Level {green} %d",
            g_Players[client].fSkillScore, g_Players[client].iSkillLevel);
    }
    else
    {
        CPrintToChat(client, "{gold}GOKZ.TOP {grey}| {default}Your skill level data is not loaded yet, retrying...");
        OnClientPutInServer(client);
    }

    return Plugin_Handled;
}
