package com.example.team_run_challenge

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.permission.HealthPermission
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.time.Instant
import kotlinx.coroutines.runBlocking

class MainActivity : FlutterFragmentActivity() {
    private lateinit var methodChannel: MethodChannel
    private lateinit var permissionLauncher: ActivityResultLauncher<Set<String>>
    private var pendingResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        permissionLauncher = registerForActivityResult(
            PermissionController.createRequestPermissionResultContract()
        ) { grantedPermissions: Set<String> ->
            val hasDistanceRead = grantedPermissions.contains(
                HealthPermission.getReadPermission(DistanceRecord::class)
            )
            val hasExerciseRead = grantedPermissions.contains(
                HealthPermission.getReadPermission(ExerciseSessionRecord::class)
            )
            val hasHistoryRead = grantedPermissions.contains(
                "android.permission.health.READ_HEALTH_DATA_HISTORY"
            )
            Log.d(
                "HealthConnect",
                "Permission result received. Granted=$grantedPermissions hasDistanceRead=$hasDistanceRead hasExerciseRead=$hasExerciseRead hasHistoryRead=$hasHistoryRead",
            )
            pendingResult?.success(hasDistanceRead && hasExerciseRead && hasHistoryRead)
            pendingResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "team_run_challenge/health_connect")
        methodChannel.setMethodCallHandler { call, result ->
            Log.d("HealthConnect", "Method called: ${call.method} args=${call.arguments}")
            when (call.method) {
                "checkHealthConnectAvailability" -> {
                    try {
                        val status = HealthConnectClient.getSdkStatus(applicationContext)
                        Log.d("HealthConnect", "SDK status = $status")
                        val isAvailable = status == HealthConnectClient.SDK_AVAILABLE ||
                            status == HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED
                        val response = if (isAvailable) "AVAILABLE" else "UNAVAILABLE"
                        Log.d("HealthConnect", "Availability response = $response")
                        result.success(response)
                    } catch (e: Exception) {
                        Log.e("HealthConnect", "Availability check failed", e)
                        result.success("UNAVAILABLE")
                    }
                }
                "requestDistanceAccess" -> {
                    Log.d("HealthConnect", "Launching permission request")
                    try {
                        val status = HealthConnectClient.getSdkStatus(applicationContext)
                        Log.d("HealthConnect", "Permission status before launch = $status")
                        if (status == HealthConnectClient.SDK_UNAVAILABLE) {
                            Log.w("HealthConnect", "Health Connect unavailable, permission request aborted")
                            result.success(false)
                            return@setMethodCallHandler
                        }
                    } catch (e: Exception) {
                        Log.e("HealthConnect", "Health Connect status check failed", e)
                        result.success(false)
                        return@setMethodCallHandler
                    }

                    pendingResult = result
                    val permissions = setOf(
                        HealthPermission.getReadPermission(DistanceRecord::class),
                        HealthPermission.getReadPermission(ExerciseSessionRecord::class),
                        HealthPermission.getReadPermission(TotalCaloriesBurnedRecord::class),
                        "android.permission.health.READ_HEALTH_DATA_HISTORY",
                    )
                    Log.d("HealthConnect", "Launching request for permissions=$permissions")
                    permissionLauncher.launch(permissions)
                }
                "getRunningSessionsInRange" -> {
                    val startMillis = call.argument<Long>("startMillis")
                    val endMillis = call.argument<Long>("endMillis")
                    Log.d("HealthConnect", "getRunningSessionsInRange startMillis=$startMillis endMillis=$endMillis")
                    if (startMillis == null || endMillis == null) {
                        result.error("bad_args", "Missing startMillis/endMillis", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val client = HealthConnectClient.getOrCreate(applicationContext)
                        val response = runBlocking {
                            client.readRecords(
                                ReadRecordsRequest(
                                    recordType = ExerciseSessionRecord::class,
                                    timeRangeFilter = TimeRangeFilter.between(
                                        Instant.ofEpochMilli(startMillis),
                                        Instant.ofEpochMilli(endMillis),
                                    ),
                                ),
                            )
                        }

                        val runningTypes = setOf(
                            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING,
                            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL,
                        )

                        val runningSessions = response.records
                            .filter { record -> runningTypes.contains(record.exerciseType) }
                            .map { record ->
                                mapOf(
                                    "startMillis" to record.startTime.toEpochMilli(),
                                    "endMillis" to record.endTime.toEpochMilli(),
                                    "exerciseType" to record.exerciseType,
                                )
                            }

                        Log.d("HealthConnect", "Loaded ${response.records.size} total exercise sessions, ${runningSessions.size} running sessions")
                        result.success(
                            mapOf(
                                "totalSessions" to response.records.size,
                                "runningSessions" to runningSessions,
                            ),
                        )
                    } catch (e: Exception) {
                        Log.e("HealthConnect", "Failed to load running sessions", e)
                        result.error("read_failed", e.message, null)
                    }
                }
                else -> {
                    Log.w("HealthConnect", "Unhandled method call: ${call.method}")
                    result.notImplemented()
                }
            }
        }
    }
}
