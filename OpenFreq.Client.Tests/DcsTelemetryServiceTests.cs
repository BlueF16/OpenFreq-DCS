using System;
using System.Text;
using OpenFreqClient.Services;

namespace OpenFreq.Client.Tests;

public sealed class DcsTelemetryServiceTests
{
    private static byte[] Packet(string aircraft = "F-14B", string? ptt = "true",
        string? tx = "1", string? frequencyHz = "251000000") =>
        Encoding.UTF8.GetBytes("""
        {
          "schema":"openfreq.dcs.telemetry.v1", "sequence":42,
          "aircraft":{"name":"AIRCRAFT", "position":{"x":1200.5,"y":2300,"z":-450}},
          "radios":[
            {"id":1,"frequency_hz":FREQ,"power_on":true,"volume":0.8,"modulation":"AM","ptt_pressed":true},
            {"id":2,"frequency_hz":124800000,"power_on":false,"volume":0.2,"modulation":"AM","ptt_pressed":false}
          ],
          "selected_tx_radio":TX, "ptt_pressed":PTT
        }
        """.Replace("AIRCRAFT", aircraft).Replace("FREQ", frequencyHz ?? "null")
            .Replace("TX", tx ?? "null").Replace("PTT", ptt ?? "null"));

    [Fact]
    public void ParsesNativeF14TelemetryAndConvertsHzToKhz()
    {
        var frame = DcsTelemetryService.Parse(Packet());
        Assert.NotNull(frame);
        Assert.Equal("F-14B", frame.Aircraft);
        Assert.Equal(42, frame.Sequence);
        Assert.Equal(1, frame.SelectedTxRadio);
        Assert.True(frame.PttPressed);
        Assert.Equal(251000, frame.Radios[1].FrequencyKhz);
        Assert.Equal("AM", frame.Radios[1].Modulation);
        Assert.Equal(0.8, frame.Radios[1].Volume);
        Assert.False(frame.Radios[2].PowerOn);
        Assert.Equal(1200.5, frame.WorldX);
        Assert.Equal(-450, frame.WorldZ);
    }

    [Fact]
    public void NullPTTMustNotBecomeFalse()
    {
        var frame = DcsTelemetryService.Parse(Packet(ptt: null, tx: null));
        Assert.NotNull(frame);
        Assert.Null(frame.PttPressed);
        Assert.Null(frame.SelectedTxRadio);
    }

    [Fact]
    public void InvalidFrequencyMustNotReuseUnverifiedValue()
    {
        var frame = DcsTelemetryService.Parse(Packet(frequencyHz: null));
        Assert.NotNull(frame);
        Assert.Null(frame.Radios[1].FrequencyKhz);
    }

    [Theory]
    [InlineData("FA-18C_hornet")]
    [InlineData("")]
    public void OtherAircraftIgnored(string model)
    {
        Assert.Null(DcsTelemetryService.Parse(Packet(aircraft: model)));
    }

    [Fact]
    public void WrongSchemaRejected()
    {
        var data = Packet();
        var message = Encoding.UTF8.GetString(data).Replace("openfreq.dcs.telemetry.v1", "other.schema");
        Assert.Null(DcsTelemetryService.Parse(Encoding.UTF8.GetBytes(message)));
    }
}
