//
//  simDataRequest.swift
//  simStock21
//
//  Created by peiyu on 2020/7/11.
//  Copyright © 2020 peiyu. All rights reserved.
//

import UIKit
import BackgroundTasks
import SwiftData

protocol TechnicalService: AnyObject {
    var progressTWSE: Int? { get set }
    var countTWSE: Int? { get set }
    var errorTWSE: Int { get set }
    func twseRequest(stock: Stock, dateStart: Date, stockGroup: DispatchGroup)
}

public class backgroundRequest {
    
    private let context: ModelContext
    private let technical: TechnicalService

    init(context: ModelContext, technical: TechnicalService) {
        self.context = context
        self.technical = technical
    }
    
    func registerBGTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.mystock.simStock21.BGTask", using: nil) { (task) in
            self.reviseWithTWSE(bgTask: task)
        }
    }
    
    func submitBGTask(_ id:String) {
        let earliest:TimeInterval = 1200
        let request = BGProcessingTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest) //背景預留時間
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
            simLog.addLog("submit BGTask, earliest: \(earliest)s")
        } catch {
            simLog.addLog("Failed to submit BGTask.")
        }

    }

    func reviseWithTWSE(_ stocks:[Stock]?=nil, bgTask:BGTask?=nil) {
        var rStocks = stocks ?? {
            let descriptor = FetchDescriptor<Stock>()
            return (try? context.fetch(descriptor)) ?? []
        }()
        var twseBugs:[Stock:Date] = [:]
        
        var timeRemain:String {
            if bgTask == nil {
                return ""
            } else if UIApplication.shared.backgroundTimeRemaining > 1800 {
                return "背景剩餘時間超過30分鐘！"
            } else {
                return String(format:"背景剩餘時間: %.3fs",UIApplication.shared.backgroundTimeRemaining)
            }
        }
        
        var errorCount:Int = 0

        func requestTWSE(_ requestStocks:[Stock], bgTask:BGTask?=nil) {
            var requests = requestStocks
            let stockGroup:DispatchGroup = DispatchGroup()
            if let stock = requests.first {
                if let dateStart = stock.dateRequestTWSE(in: context) {
                    if let dt = twseBugs[stock], dt == dateStart {
                        simLog.addLog("\(stock.sId)\(stock.sName) 略過。 \(timeRemain)")
                    } else {
                        stockGroup.enter()
                        let progress = technical.progressTWSE ?? 0
                        let delay:Int = (progress % 5 == 0 ? 9 : 3) + (progress % 7 == 0 ? 3 : 0)
                        technical.progressTWSE = rStocks.count - requests.count + 1
                        DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + .seconds(delay)) {
                            self.technical.twseRequest(stock: stock, dateStart: dateStart, stockGroup: stockGroup)
                        }
                        if dateStart == twDateTime.yesterday() {
                            requests.append(stock)  //復驗是到昨天，可能只抓今天1筆，就再多排一次
                            rStocks.append(stock)
                            technical.countTWSE = rStocks.count
                        }
                        if let last = try? stock.lastTrade(in: context) {
                            if let d = twDateTime.calendar.dateComponents([.day], from: stock.dateRequestStart, to: last.dateTime).day, d > 31 {
                                requests.append(stock)  //起始後缺超過3個月，就再趕一下進度
                                rStocks.append(stock)
                                technical.countTWSE = rStocks.count
                            }
                        }
                        stockGroup.wait()
                        if technical.errorTWSE != errorCount {
                            twseBugs[stock] = dateStart
                            errorCount = technical.errorTWSE
                            simLog.addLog("\(stock.sId)\(stock.sName) error:\(errorCount) \(timeRemain)")
                        }
                    }
                }
                if technical.errorTWSE < 3 {
                    requests.removeFirst()
                    if requests.count > 0 {
                        requestTWSE(requests, bgTask: bgTask)
                    } else {
                        simLog.addLog("TWSE(\(rStocks.count))完成。 \(timeRemain)")
                        if let task = bgTask {
                            task.setTaskCompleted(success: true)
                        }
                        technical.errorTWSE = 0
                        technical.progressTWSE = nil
                        technical.countTWSE = nil
                    }
                } else {
                    simLog.addLog("TWSE(\(technical.progressTWSE ?? 0)/\(rStocks.count))中斷！ \(timeRemain)")
                    if let task = bgTask {
                        task.setTaskCompleted(success: false)
                    }
                    technical.errorTWSE = 0
                    technical.progressTWSE = nil
                    technical.countTWSE = nil
                }
            }
        }   //func reviseWithTWSE
        
        if let task = bgTask {
            task.expirationHandler = { [self] in
                simLog.addLog("BGTask expired. \(timeRemain)")
                technical.errorTWSE = 0
                technical.progressTWSE = nil
                technical.countTWSE = nil
                task.setTaskCompleted(success: false)
            }
        }
        if bgTask == nil {
            simLog.addLog("TWSE復驗。")
        } else {
            simLog.addLog("背景啟動。 \(timeRemain)")
        }
        technical.countTWSE = rStocks.count
        requestTWSE(rStocks)
        
    }
    

}

