<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <UiMod name="EZAssist" version="1.0.0" date="2026-10-28">
        <Author name="Talladego" email="" />
        <Description text="EZAssist: managed /assist macro by KillDamage → Deathblows → Total Damage in scenarios and party/warband. Bind the EZAssist macro and press it yourself." />
        <VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />

        <Dependencies>
            <Dependency name="EASystem_Utils" />
            <Dependency name="EA_MacroWindow" />
            <Dependency name="EASystem_ActionBarClusterManager" optional="true" />
            <Dependency name="LibSlash" optional="true" forceEnable="true" />
        </Dependencies>

        <Files>
            <File name="EZAssist_Icons.xml" />
            <File name="EZAssist_ScenarioStats.lua" />
            <File name="EZAssist_GroupStats.lua" />
            <File name="EZAssist_Controller.lua" />
            <File name="EZAssist.lua" />
        </Files>

        <SavedVariables>
            <SavedVariable name="EZAssist.Settings" global="true" />
        </SavedVariables>

        <OnInitialize>
            <CallFunction name="EZAssist.OnInitialize" />
        </OnInitialize>
        <OnUpdate>
            <CallFunction name="EZAssist.OnUpdate" />
        </OnUpdate>
        <OnShutdown>
            <CallFunction name="EZAssist.OnShutdown" />
        </OnShutdown>

        <WARInfo>
            <Categories>
                <Category name="COMBAT" />
                <Category name="RVR" />
                <Category name="GROUPING" />
            </Categories>
        </WARInfo>
    </UiMod>
</ModuleFile>
