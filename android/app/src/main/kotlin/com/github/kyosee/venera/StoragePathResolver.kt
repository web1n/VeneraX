package io.github.kyosee.venera

import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import java.io.File

/** Resolves only the selected grant using the pinned SAF plugin's root-ID
 * format. Unsupported or ambiguous providers retain their SAF path.
 */
object StoragePathResolver {
    fun resolve(context: Context, selectedPath: String): String? {
        return try {
            val prefix = "android://"
            if (!selectedPath.startsWith(prefix)) return null
            val selectedId = selectedPath.removePrefix(prefix)
            if (selectedId.isEmpty()) return null
            val matches = context.contentResolver.persistedUriPermissions.filter { permission ->
                try {
                    DocumentsContract.getTreeDocumentId(permission.uri) == selectedId
                } catch (_: Exception) {
                    false
                }
            }
            // The plugin ID omits authority, so ambiguous grants stay on SAF.
            val permission = matches.singleOrNull() ?: return null
            if (!permission.isReadPermission || !permission.isWritePermission ||
                permission.uri.authority != "com.android.externalstorage.documents") return null
            val separator = selectedId.indexOf(':')
            if (separator <= 0) return null
            val volumeId = selectedId.substring(0, separator)
            val relative = selectedId.substring(separator + 1)
            val storage = context.getSystemService(Context.STORAGE_SERVICE) as StorageManager
            val root = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                storage.storageVolumes.firstOrNull { volume ->
                    if (volumeId == "primary") volume.isPrimary
                    else volume.uuid?.equals(volumeId, ignoreCase = true) == true
                }?.directory
            } else if (volumeId == "primary") {
                Environment.getExternalStorageDirectory()
            } else null
            if (root == null || relative.startsWith('/')) return null
            val canonicalRoot = root.canonicalFile
            val directory = File(canonicalRoot, relative).canonicalFile
            if (directory != canonicalRoot &&
                !directory.path.startsWith(canonicalRoot.path + File.separator)) return null
            if (directory.isDirectory && directory.canRead() && directory.canWrite()) {
                directory.path
            } else null
        } catch (_: Exception) {
            null
        }
    }
}
