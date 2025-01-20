using System;
using System.Collections.Generic;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Npgsql;
using DotnetWeatherApi.Models;

namespace DotnetWeatherApi.Controllers
{
    [ApiController]
    [Route("[controller]")]
    public class WeatherController : ControllerBase
    {
        private readonly IConfiguration _configuration;

        public WeatherController(IConfiguration configuration)
        {
            _configuration = configuration;
        }

        [HttpGet("random")]
        public IActionResult GetRandomTemperature()
        {
            // Генерируем случайное число от 10 до 30
            var random = new Random();
            int temp = random.Next(10, 31); // 10..30

            return Ok(new { temperatureC = temp, recordedAt = DateTime.UtcNow });
        }

        [HttpGet("all")]
        public IActionResult GetAllRecords()
        {
            // Читаем строку подключения из appsettings.json или переменных окружения
            var connStr = _configuration.GetConnectionString("WeatherDb");
            var records = new List<TemperatureRecord>();

            using (var conn = new NpgsqlConnection(connStr))
            {
                conn.Open();
                string query = "SELECT id, temperature_c, recorded_at FROM temperature_records ORDER BY id DESC";
                using (var cmd = new NpgsqlCommand(query, conn))
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        records.Add(new TemperatureRecord
                        {
                            Id = reader.GetInt32(0),
                            TemperatureC = reader.GetInt32(1),
                            RecordedAt = reader.GetDateTime(2)
                        });
                    }
                }
            }

            return Ok(records);
        }

        [HttpPost("insert-random")]
        public IActionResult InsertRandomTemperature()
        {
            var random = new Random();
            int temp = random.Next(10, 31);

            var connStr = _configuration.GetConnectionString("WeatherDb");

            using (var conn = new NpgsqlConnection(connStr))
            {
                conn.Open();
                string insertQuery = "INSERT INTO temperature_records(temperature_c, recorded_at) VALUES(@temp, @time)";
                using (var cmd = new NpgsqlCommand(insertQuery, conn))
                {
                    cmd.Parameters.AddWithValue("temp", temp);
                    cmd.Parameters.AddWithValue("time", DateTime.UtcNow);
                    cmd.ExecuteNonQuery();
                }
            }

            return Ok($"Inserted random temperature: {temp}C");
        }
    }
}
