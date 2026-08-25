@preconcurrency import CoreML
import Foundation

actor Maia3CoreMLPolicyModel: Maia3PolicyPredicting {
    static let shared = Maia3CoreMLPolicyModel()

    private var model: MLModel?

    func predict(input: Maia3PolicyInput) async throws -> [Double] {
        try Task.checkCancellation()
        let model = try loadModelIfNeeded()

        do {
            let boardHistory = try MLMultiArray(
                shape: [1, 64, 96],
                dataType: .float32
            )
            for (index, value) in input.boardHistory.enumerated() {
                boardHistory[index] = NSNumber(value: value)
            }

            let selfRating = try MLMultiArray(shape: [1], dataType: .float32)
            selfRating[0] = NSNumber(value: input.selfRating)
            let opponentRating = try MLMultiArray(shape: [1], dataType: .float32)
            opponentRating[0] = NSNumber(value: input.opponentRating)

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "board_history": boardHistory,
                "self_rating": selfRating,
                "opponent_rating": opponentRating,
            ])
            let prediction = try model.prediction(from: provider)
            try Task.checkCancellation()

            guard let output = prediction.featureValue(for: "move_logits")?.multiArrayValue,
                  output.count == Maia3MoveVocabulary.count
            else {
                throw ChessPlayingEngineError.inference(
                    "La salida move_logits del modelo Maia 3 no tiene el formato esperado."
                )
            }

            return (0..<output.count).map { output[$0].doubleValue }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChessPlayingEngineError {
            throw error
        } catch {
            throw ChessPlayingEngineError.inference(
                "Falló la inferencia local de Maia 3: \(error.localizedDescription)"
            )
        }
    }

    private func loadModelIfNeeded() throws -> MLModel {
        if let model { return model }

        let modelURL: URL
        if let compiledURL = Bundle.main.url(
            forResource: "Maia3_5M",
            withExtension: "mlmodelc"
        ) {
            modelURL = compiledURL
        } else if let packageURL = Bundle.main.url(
            forResource: "Maia3_5M",
            withExtension: "mlpackage"
        ) {
            modelURL = try MLModel.compileModel(at: packageURL)
        } else {
            throw ChessPlayingEngineError.unavailable(
                "No se encontró el modelo local Maia3-5M en la aplicación."
            )
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
            model = loaded
            return loaded
        } catch {
            throw ChessPlayingEngineError.unavailable(
                "No se pudo cargar Maia3-5M: \(error.localizedDescription)"
            )
        }
    }
}
