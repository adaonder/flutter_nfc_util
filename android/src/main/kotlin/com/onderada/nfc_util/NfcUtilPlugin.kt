package com.onderada.nfc_util

import android.app.Activity
import android.nfc.*
import android.nfc.tech.*
import android.os.Build
import android.util.Log
import java.util.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class NfcUtilPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var adapter: NfcAdapter? = null
    private var connectedTech: TagTechnology? = null
    private var tags: MutableMap<String, Tag> = mutableMapOf()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "nfc_util")
        channel.setMethodCallHandler(this)
        adapter = NfcAdapter.getDefaultAdapter(binding.applicationContext)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "Nfc#isAvailable" -> result.success(adapter?.isEnabled == true)
            "Nfc#startSession" -> startSession(result, call)
            "Nfc#stopSession" -> stopSession(result)
            else -> result.notImplemented()
        }
    }

    private fun startSession(result: MethodChannel.Result, call: MethodCall) {
        val adapter = adapter ?: run {
            result.error("unavailable", "NFC is not available for device.", null)
            return
        }

        Log.d("NfcUtilPlugin", "test 1")

        val currentActivity = activity ?: run {
            result.error("no_activity", "No activity attached.", null)
            return
        }

        val pollingOptions = call.argument<List<String>>("pollingOptions") ?: listOf("iso14443")
        val flags = getFlags(pollingOptions)

        Log.d("NfcUtilPlugin", "Polling options: $pollingOptions")
        Log.d("NfcUtilPlugin", "adapter: 1")
        Log.d("NfcUtilPlugin", "flags: $flags")


        adapter.enableReaderMode(currentActivity, { tag ->
            val handle = UUID.randomUUID().toString()
            Log.d("NfcUtilPlugin", "handle: $handle")
            tags[handle] = tag
            currentActivity.runOnUiThread {
                channel.invokeMethod(
                    "onDiscovered",
                    mapOf("handle" to handle, "id" to tag.id.joinToString("") { "%02x".format(it) })
                )
            }
        }, flags, null)

        result.success(null)
    }

    private fun stopSession(result: MethodChannel.Result) {
        val adapter = adapter ?: run {
            result.error("unavailable", "NFC is not available for device.", null)
            return
        }
        val currentActivity = activity ?: run {
            result.error("no_activity", "No activity attached.", null)
            return
        }

        adapter.disableReaderMode(currentActivity)
        result.success(null)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
