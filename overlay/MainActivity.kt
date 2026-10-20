package com.luis.obd_libre

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

@Suppress("MissingPermission", "DEPRECATION")
class MainActivity : FlutterActivity() {
    private var socket: BluetoothSocket? = null
    private val io = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())
    private var permResult: MethodChannel.Result? = null
    private val spp: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "obd/bt")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "permission" -> askPermission(result)
                    "bonded" -> bonded(result)
                    "connect" -> connect(call.argument<String>("address") ?: "", result)
                    "request" -> request(
                        call.argument<String>("cmd") ?: "",
                        call.argument<Int>("timeout") ?: 4000,
                        result
                    )
                    "close" -> { close(); result.success(true) }
                    else -> result.notImplemented()
                }
            }
    }

    private fun askPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 31 &&
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) {
            permResult = result
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 7)
        } else {
            result.success(true)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7) {
            permResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            permResult = null
        }
    }

    private fun bonded(result: MethodChannel.Result) {
        val a = BluetoothAdapter.getDefaultAdapter()
        if (a == null) { result.error("BT", "Este dispositivo no tiene Bluetooth", null); return }
        if (!a.isEnabled) { result.error("BT", "Activa el Bluetooth", null); return }
        val list = a.bondedDevices.map { mapOf("name" to (it.name ?: "?"), "address" to it.address) }
        result.success(list)
    }

    private fun connect(address: String, result: MethodChannel.Result) {
        io.execute {
            try {
                close()
                val a = BluetoothAdapter.getDefaultAdapter()
                a.cancelDiscovery()
                val dev = a.getRemoteDevice(address)
                var s = dev.createRfcommSocketToServiceRecord(spp)
                try {
                    s.connect()
                } catch (e: Exception) {
                    try { s.close() } catch (_: Exception) {}
                    s = dev.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                        .invoke(dev, 1) as BluetoothSocket
                    s.connect()
                }
                socket = s
                ui.post { result.success(true) }
            } catch (e: Exception) {
                ui.post { result.error("BT", e.message ?: "No se pudo conectar", null) }
            }
        }
    }

    private fun request(cmd: String, timeout: Int, result: MethodChannel.Result) {
        io.execute {
            try {
                val s = socket ?: throw Exception("Sin conexión")
                val out = s.outputStream
                val inp = s.inputStream
                while (inp.available() > 0) inp.read()
                out.write((cmd + "\r").toByteArray())
                out.flush()
                val sb = StringBuilder()
                val end = System.currentTimeMillis() + timeout
                while (System.currentTimeMillis() < end) {
                    if (inp.available() > 0) {
                        val c = inp.read()
                        if (c < 0) break
                        val ch = c.toChar()
                        if (ch == '>') break
                        sb.append(ch)
                    } else {
                        Thread.sleep(5)
                    }
                }
                val text = sb.toString()
                ui.post { result.success(text) }
            } catch (e: Exception) {
                ui.post { result.error("BT", e.message ?: "Error de lectura", null) }
            }
        }
    }

    private fun close() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
    }
}
