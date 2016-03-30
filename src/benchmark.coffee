fhir_benchmark = (plv8, query)->
  create_patients = (limit)->
    """
    SELECT count(
             fhir_create_resource(
               fhir_benchmark_dissoc(patients.resource::json, 'id')
             )
           )
           FROM (SELECT resource FROM patient LIMIT #{limit}) patients;
    """

  benchmarks = [
    {
      statement: create_patients(1)
      discrition: 'fhir_create_resource called just one time'
    },
    {
      statement: create_patients(1000)
      discrition: 'fhir_create_resource called 1000 times in batch'
    }
  ]

  benchmarks = benchmarks.map (benchmark)->
    t1 = new Date()
    plv8.execute(benchmark.statement)
    t2 = new Date()
    {
      description: benchmark.discrition
      time: "#{t2 - t1} ms"
    }

  {operations: benchmarks}

exports.fhir_benchmark = fhir_benchmark
exports.fhir_benchmark.plv8_signature = ['json', 'json']

fhir_benchmark_dissoc = (plv8, obj, property)->
  delete obj[property]
  obj

exports.fhir_benchmark_dissoc = fhir_benchmark_dissoc
exports.fhir_benchmark_dissoc.plv8_signature = {
  arguments: ['json', 'text']
  returns: 'json'
  immutable: true
}