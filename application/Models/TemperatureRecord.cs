using System;

namespace DotnetWeatherApi.Models
{
    public class TemperatureRecord
    {
        public int Id { get; set; }
        public int TemperatureC { get; set; }
        public DateTime RecordedAt { get; set; }
    }
}
