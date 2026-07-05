package com.example.team_run_challenge

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
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
            Log.d(
                "HealthConnect",
                "Permission result received. Granted=$grantedPermissions hasDistanceRead=$hasDistanceRead hasExerciseRead=$hasExerciseRead",
            )
            pendingResult?.success(hasDistanceRead && hasExerciseRead)
            pendingResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "team_run_challenge/health_connect")
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkHealthConnectAvailability" -> {
                    val status = HealthConnectClient.getSdkStatus(applicationContext)
                    Log.d("HealthConnect", "SDK status = $status")
                    result.success(status == HealthConnectClient.SDK_AVAILABLE)
                }
                "requestDistanceAccess" -> {
                    Log.d("HealthConnect", "Launching permission request")
                    pendingResult = result
                    val permissions = setOf(
                        HealthPermission.getReadPermission(DistanceRecord::class),
                        HealthPermission.getReadPermission(ExerciseSessionRecord::class),
                    )
                    permissionLauncher.launch(permissions)
                }
                "getRunningSessionsInRange" -> {
                    val startMillis = call.argument<Long>("startMillis")
                    val endMillis = call.argument<Long>("endMillis")
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

                        result.success(
                            mapOf(
                                "totalSessions" to response.records.size,
                                "runningSessions" to runningSessions,
                            ),
                        )
                    } catch (e: Exception) {
                        result.error("read_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
