# Patches flutter_media_session to add missing kotlin-android plugin.
# Run this after `flutter pub get` if the build fails with "Unresolved reference: kotlinOptions".
$pluginBuild = "$env:LOCALAPPDATA\pub\cache\hosted\pub.dev\flutter_media_session-2.3.0\android\build.gradle.kts"
if (Test-Path $pluginBuild) {
    $content = Get-Content $pluginBuild -Raw
    if (-not $content.Contains('id("kotlin-android")')) {
        $content = $content.Replace('id("com.android.library")', 'id("com.android.library")' + "`n    id(`"kotlin-android`")")
        Set-Content $pluginBuild $content -NoNewline
        Write-Host "Successfully patched flutter_media_session build.gradle.kts"
    } else {
        Write-Host "flutter_media_session build.gradle.kts is already patched"
    }
} else {
    Write-Host "Warning: flutter_media_session path not found at $pluginBuild"
}
