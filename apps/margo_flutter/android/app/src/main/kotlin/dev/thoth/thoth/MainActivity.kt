package dev.thoth.thoth

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.thoth.app/updates")
            .setMethodCallHandler { call, result ->
                if (call.method != "install") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val path = requireNotNull(call.argument<String>("path"))
                    val file = File(path).canonicalFile
                    val folder = File(cacheDir, "margo-updates").canonicalFile
                    require(file.parentFile == folder && file.extension == "apk" && file.isFile)
                    @Suppress("DEPRECATION")
                    val archive = requireNotNull(packageManager.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES))
                    @Suppress("DEPRECATION")
                    val installed = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                    require(archive.packageName == packageName)
                    require(PackageInfoCompat.getLongVersionCode(archive) > PackageInfoCompat.getLongVersionCode(installed))
                    @Suppress("DEPRECATION")
                    require(archive.signatures?.toSet() == installed.signatures?.toSet() && !archive.signatures.isNullOrEmpty())
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        result.success("permission")
                    } else {
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                        startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        result.success("installer")
                    }
                } catch (e: Exception) {
                    result.error("INSTALL_FAILED", "Unable to open verified application update", null)
                }
            }
    }
}
