using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;

namespace OpenFreqClient.Services;

/// <summary>One DCS exporter frame. Unknown telemetry is null, never interpreted as TX OFF.</summary>
public sealed record DcsRadioState(int Id, int? FrequencyKhz, bool? PowerOn, double? Volume,
    string? Modulation, bool? PttPressed);

public sealed record DcsTelemetrySnapshot(string Aircraft, long Sequence, int? SelectedTxRadio,
    bool? PttPressed, IReadOnlyDictionary<int, DcsRadioState> Radios,
    double? WorldX, double? WorldY, double? WorldZ);

public interface IDcsTelemetryService : IDisposable
{
    DcsTelemetrySnapshot? Latest { get; }
    bool IsActive { get; }
    event EventHandler<DcsTelemetrySnapshot?>? SnapshotChanged;
    void Start();
    void Stop();
}

/// <summary>
/// Ingests openfreq.dcs.telemetry.v1 exclusively from loopback port 29340.
/// An expired stream revokes TX, so radio silence cannot leave PTT latched.
/// </summary>
public sealed class DcsTelemetryService(ILogger<DcsTelemetryService> logger) : IDcsTelemetryService
{
    public const int Port = 29340;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(1.5);
    private readonly object _gate = new();
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private DcsTelemetrySnapshot? _latest;
    private DateTime _receivedAt;
    private long _previousSequence = -1;

    public DcsTelemetrySnapshot? Latest { get { lock (_gate) return IsActiveLocked() ? _latest : null; } }
    public bool IsActive { get { lock (_gate) return IsActiveLocked(); } }
    private bool IsActiveLocked() => _latest != null && DateTime.UtcNow - _receivedAt <= Timeout;
    public event EventHandler<DcsTelemetrySnapshot?>? SnapshotChanged;

    public void Start()
    {
        lock (_gate)
        {
            if (_cts != null) return;
            // Intentionally no wildcard binding: do not accept remote PTT over UDP.
            _udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, Port));
            _cts = new CancellationTokenSource();
            _previousSequence = -1;
            var socket = _udp!;
            var cancellation = _cts.Token;
            _ = Task.Run(() => RunAsync(socket, cancellation));
        }
        logger.LogInformation("DCS telemetry listening on 127.0.0.1:{Port}", Port);
    }

    private async Task RunAsync(UdpClient socket, CancellationToken cancellation)
    {
        Task<UdpReceiveResult>? pending = null;
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                pending ??= socket.ReceiveAsync(cancellation).AsTask();
                var completed = await Task.WhenAny(pending, Task.Delay(250, cancellation));
                if (completed != pending)
                {
                    bool expired;
                    lock (_gate)
                    {
                        expired = _latest != null && !IsActiveLocked();
                        if (expired) { _latest = null; _previousSequence = -1; }
                    }
                    if (expired) SnapshotChanged?.Invoke(this, null);
                    continue;
                }
                else
                {
                    var packet = await pending;
                    pending = null;
                    HandlePacket(packet.Buffer);
                }
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException ex) when (cancellation.IsCancellationRequested) { logger.LogDebug(ex, "DCS UDP closed"); break; }
            catch (Exception ex) { logger.LogWarning(ex, "Ignoring malformed DCS telemetry"); }
        }
    }

    private void HandlePacket(byte[] bytes)
    {
        if (bytes.Length > 48 * 1024) return;
        DcsTelemetrySnapshot? snapshot;
        try { snapshot = Parse(bytes); }
        catch (JsonException) { return; }
        if (snapshot == null) return;
        lock (_gate)
        {
            if (_cts == null || _cts.IsCancellationRequested) return;
            if (IsActiveLocked() && snapshot.Sequence <= _previousSequence) return;
            _latest = snapshot;
            _receivedAt = DateTime.UtcNow;
            _previousSequence = snapshot.Sequence;
        }
        SnapshotChanged?.Invoke(this, snapshot);
    }

    public static DcsTelemetrySnapshot? Parse(byte[] bytes)
    {
        using var doc = JsonDocument.Parse(bytes);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            ReadString(root, "schema") != "openfreq.dcs.telemetry.v1") return null;
        if (!root.TryGetProperty("sequence", out var seq) || seq.ValueKind != JsonValueKind.Number ||
            !seq.TryGetInt64(out var sequence) || sequence < 0)
            return null;
        if (!root.TryGetProperty("aircraft", out var plane) || plane.ValueKind != JsonValueKind.Object)
            return null;
        var aircraft = ReadString(plane, "name") ?? string.Empty;
        // Do not implicitly select DCS based on a menu, spectator, or another module.
        if (!aircraft.StartsWith("F-14", StringComparison.OrdinalIgnoreCase)) return null;
        if (!root.TryGetProperty("radios", out var radiosJson) || radiosJson.ValueKind != JsonValueKind.Array)
            return null;
        var radios = new Dictionary<int, DcsRadioState>();
        foreach (var radio in radiosJson.EnumerateArray())
        {
            if (radio.ValueKind != JsonValueKind.Object) continue;
            var id = ReadInt(radio, "id");
            if (id is not (1 or 2)) continue;
            var hz = ReadDouble(radio, "frequency_hz");
            int? khz = hz is >= 20000000 and <= 500000000 ? (int)Math.Round(hz.Value / 1000d) : null;
            var gain = ReadDouble(radio, "volume");
            radios[id.Value] = new DcsRadioState(id.Value, khz,
                ReadBool(radio, "power_on"), gain is >= 0 and <= 1 ? gain : null,
                ReadString(radio, "modulation"), ReadBool(radio, "ptt_pressed"));
        }
        // Preserve validity distinction: no data means no assertion about the radio.
        if (radios.Count == 0) return null;
        var txId = ReadInt(root, "selected_tx_radio");
        if (txId is not (0 or 1 or 2)) txId = null;
        var position = plane.TryGetProperty("position", out var pos) && pos.ValueKind == JsonValueKind.Object
            ? pos : default;
        return new DcsTelemetrySnapshot(aircraft, sequence, txId, ReadBool(root, "ptt_pressed"), radios,
            ReadDouble(position, "x"), ReadDouble(position, "y"), ReadDouble(position, "z"));
    }

    private static string? ReadString(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;
    private static int? ReadInt(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var x)
            ? x : null;
    private static bool? ReadBool(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var v)
            ? v.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null } : null;
    private static double? ReadDouble(JsonElement obj, string name)
    {
        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out var v) ||
            v.ValueKind != JsonValueKind.Number || !v.TryGetDouble(out var x) || !double.IsFinite(x)) return null;
        return x;
    }

    public void Stop()
    {
        UdpClient? socket;
        lock (_gate)
        {
            socket = _udp;
            _cts?.Cancel();
            _cts?.Dispose();
            _cts = null;
            _udp = null;
            _latest = null;
            _previousSequence = -1;
        }
        socket?.Dispose();
        SnapshotChanged?.Invoke(this, null);
    }
    public void Dispose() => Stop();
}
